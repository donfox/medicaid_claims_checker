{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.Parser
-- Description : Parsec parser for the claims rule DSL
--
-- Parses rule text into the AST in "Claims.Syntax". The grammar is described
-- for rule authors in @docs/SYNTAX_GUIDE.md@; in short:
--
-- @
-- RULE name [DESCRIPTION] "description"
--   [LET var = path ...]
--   WHEN predicate
--   THEN action ;   (or END)
-- @
--
-- Precedence, loosest first: @OR@, @AND@, @NOT@, then atomic predicates.
module Claims.Parser
  ( parseRule,
    parseRules,
    ParseError,
  )
where

import Prelude hiding (EQ, GT, LT)
import Control.Applicative ((<|>))
import Control.Monad (void, when)
import Data.Functor (($>))
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Text.Parsec hiding ((<|>))
import Text.Parsec.Text
import Claims.SimpleEvaluator (compileRegex, helperArity)
import Claims.Syntax (Action, Binding, CompOp (..), Path (..), Predicate, Rule, Value)
import Claims.Syntax qualified as Syntax

parseRule :: Text -> Either ParseError Rule
parseRule = parse ruleParser "rule"

-- | Parse zero or more rules; the whole input must be consumed.
parseRules :: Text -> Either ParseError [Rule]
parseRules = parse rulesParser "rules"

-- ----------------------------------------------------------------------------
-- Lexical helpers
-- ----------------------------------------------------------------------------

-- | Skip spaces, tabs, newlines and @--@ line comments.
whitespace :: Parser ()
whitespace = skipMany (simpleSpace <|> lineComment)
  where
    simpleSpace = void $ oneOf " \t\n\r"
    lineComment =
      void $ try (string "--" *> manyTill anyChar (void newline <|> eof))

-- | A keyword not followed by an identifier character, so @AND@ does not
-- match the start of @ANDROID@.
keyword :: String -> Parser ()
keyword s = try $ string s *> notFollowedBy (alphaNum <|> char '_')

lexeme :: Parser a -> Parser a
lexeme p = p <* whitespace

kw :: String -> Parser ()
kw = lexeme . keyword

-- ----------------------------------------------------------------------------
-- Rules
-- ----------------------------------------------------------------------------

-- | Limits the work one request can cause: evaluation is rules × claims.
maxRuleCount :: Int
maxRuleCount = 200

rulesParser :: Parser [Rule]
rulesParser = do
  whitespace
  rules <- many ruleParser
  eof
  if length rules > maxRuleCount
    then fail $ "Rule set exceeds the maximum of " ++ show maxRuleCount ++ " rules"
    else pure rules

ruleParser :: Parser Rule
ruleParser = do
  kw "RULE"
  name <- lexeme identifier
  desc <- lexeme descriptionPart
  bindings <- many (try (lexeme bindingParser))
  let bindingNames = map Syntax.bindingName bindings
  when (length bindingNames /= length (nub bindingNames)) $
    fail "Duplicate LET name in rule"
  kw "WHEN"
  cond <- lexeme predicateParser
  kw "THEN"
  act <- lexeme actionParser
  lexeme (char ';' $> () <|> keyword "END")
  pure $ Syntax.Rule (T.pack name) (T.pack desc) bindings cond act

-- | @LET name = path@. Unlike other identifiers, the name may not start
-- with a digit.
bindingParser :: Parser Binding
bindingParser = do
  kw "LET"
  name <- lexeme (notReserved =<< ((:) <$> (letter <|> char '_') <*> many (alphaNum <|> char '_')))
  _ <- lexeme (char '=')
  Syntax.Binding (T.pack name) <$> lexeme fieldPath

descriptionPart :: Parser String
descriptionPart = try (kw "DESCRIPTION" *> stringLiteral) <|> stringLiteral

-- ----------------------------------------------------------------------------
-- Predicates
-- ----------------------------------------------------------------------------
-- Every level carries a nesting depth, so a rule with hundreds of nested
-- parentheses is rejected with a clear error instead of overflowing the
-- stack.

maxPredicateDepth :: Int
maxPredicateDepth = 50

predicateParser :: Parser Predicate
predicateParser = predAt 0

predAt :: Int -> Parser Predicate
predAt depth
  | depth > maxPredicateDepth =
      fail $ "Predicate nesting exceeds the maximum depth (" ++ show maxPredicateDepth ++ " levels)"
  | otherwise = orAt depth

orAt :: Int -> Parser Predicate
orAt depth = chainr1 (andAt depth) (Syntax.Or <$ try (whitespace *> kw "OR"))

andAt :: Int -> Parser Predicate
andAt depth = chainr1 (notAt depth) (Syntax.And <$ try (whitespace *> kw "AND"))

notAt :: Int -> Parser Predicate
notAt depth = (Syntax.Not <$> (kw "NOT" *> atomicAt depth)) <|> atomicAt depth

atomicAt :: Int -> Parser Predicate
atomicAt depth =
  choice
    [ try (quantifierAt "EXISTS" Syntax.Exists depth),
      try (quantifierAt "FORALL" Syntax.ForAll depth),
      try countPred,
      try (domainPred "has_diagnosis" Syntax.HasDiagnosis),
      try (domainPred "has_procedure" Syntax.HasProcedure),
      try helperCallPred,
      try betweenPred,
      try textPred,
      try comparisonPred,
      try nullCheckPred,
      parenAt (depth + 1),
      boolLiteral
    ]

-- | @name(arg, ...)@. The name and argument count are checked against the
-- evaluator's helper table, so a typo fails here rather than producing a
-- rule that never fires.
helperCallPred :: Parser Predicate
helperCallPred = do
  helperName <- identifier
  args <- listOf '(' ')' (try listValueParser <|> valueParser)
  case helperArity (T.pack helperName) of
    Nothing -> fail $ "Unknown helper function: " ++ helperName
    Just arity
      | arity /= length args ->
          fail $
            helperName ++ " takes " ++ show arity ++ " argument" ++ (if arity == 1 then "" else "s")
              ++ ", got " ++ show (length args)
      | otherwise -> pure $ Syntax.HelperCall (T.pack helperName) args

-- | @[1, "a", ...]@: numbers and strings only.
listValueParser :: Parser Value
listValueParser =
  Syntax.ListValue
    <$> listOf '[' ']' (try (Syntax.NumberValue <$> numberLiteral) <|> (Syntax.StringValue . T.pack <$> stringLiteral))

-- | Comma-separated items between two brackets.
listOf :: Char -> Char -> Parser a -> Parser [a]
listOf open close item =
  between (char open *> spaces) (spaces *> char close) (sepBy item (spaces *> char ',' *> spaces))

parenAt :: Int -> Parser Predicate
parenAt depth = between (char '(' *> spaces) (spaces *> char ')') (predAt depth)

-- | @EXISTS path WHERE p@ or @EXISTS var IN path WHERE p@ (likewise FORALL).
-- The body continues at the current depth, so nesting inside quantifiers is
-- bounded too.
quantifierAt :: String -> (Maybe Text -> Path -> Predicate -> Predicate) -> Int -> Parser Predicate
quantifierAt word mk depth = do
  _ <- string word *> spaces
  try named <|> body Nothing
  where
    named = do
      varName <- identifier <* spaces
      kw "IN"
      body (Just (T.pack varName))
    body var = do
      path <- collectionPath <* spaces
      _ <- string "WHERE" *> spaces
      mk var path <$> predAt depth

countPred :: Parser Predicate
countPred =
  Syntax.Count
    <$> (string "COUNT" *> spaces *> between (char '(') (char ')') (spaces *> collectionPath <* spaces))
    <*> (spaces *> compOperator)
    <*> (spaces *> intLiteral)

-- | @claim.has_diagnosis "code"@ and @claim.has_procedure "code"@.
domainPred :: String -> (Value -> Predicate) -> Parser Predicate
domainPred name mk = do
  _ <- try (string "claim" *> char '.' *> string name)
  spaces
  mk <$> valueParser

-- | @field BETWEEN lo AND hi@. This parser consumes the inner @AND@ before
-- the boolean @AND@ level sees it.
betweenPred :: Parser Predicate
betweenPred = do
  field <- fieldPath
  spaces
  kw "BETWEEN"
  lo <- lexeme valueParser
  kw "AND"
  Syntax.Between field lo <$> valueParser

-- | @field CONTAINS "text"@ or @field MATCHES "regex"@. An invalid regex is
-- a parse error, so a broken pattern is caught when the rule is written.
textPred :: Parser Predicate
textPred = do
  field <- fieldPath
  spaces
  containsTail field <|> matchesTail field
  where
    containsTail field = do
      kw "CONTAINS"
      Syntax.Contains field . Syntax.StringValue . T.pack <$> stringLiteral
    matchesTail field = do
      kw "MATCHES"
      pattern <- T.pack <$> stringLiteral
      case compileRegex pattern of
        Just _ -> pure (Syntax.Matches field pattern)
        Nothing -> fail $ "Invalid regular expression in MATCHES: " ++ T.unpack pattern

comparisonPred :: Parser Predicate
comparisonPred = do
  field <- fieldPath
  spaces
  op <- compOperator
  spaces
  Syntax.Compare op field <$> valueParser

nullCheckPred :: Parser Predicate
nullCheckPred = do
  field <- fieldPath <* spaces <* string "IS" <* spaces
  nullCheck <- (Syntax.IsNotNull <$ try (string "NOT NULL")) <|> (Syntax.IsNull <$ string "NULL")
  pure $ nullCheck field

boolLiteral :: Parser Predicate
boolLiteral = (Syntax.PTrue <$ keyword "TRUE") <|> (Syntax.PFalse <$ keyword "FALSE")

-- ----------------------------------------------------------------------------
-- Paths, values, operators
-- ----------------------------------------------------------------------------

-- | The collection in EXISTS, FORALL and COUNT: @2400@, @2400.SV1@, ...
collectionPath :: Parser Path
collectionPath =
  (\first rest -> Path (map T.pack (first : rest)))
    <$> identifier
    <*> option [] (char '.' *> sepBy1 identifier (char '.'))

-- | A field: @amount@, @CLM.amount@, @claim.billing_provider.address.zip@.
-- A dot must be followed by a name, so a trailing @.@ is left unconsumed.
fieldPath :: Parser Path
fieldPath = Path . map T.pack <$> sepBy1 identifier (try (char '.' <* lookAhead (alphaNum <|> char '_')))

valueParser :: Parser Value
valueParser =
  try (Syntax.NumberValue <$> numberLiteral)
    <|> try listValueParser
    <|> try (Syntax.FieldValue <$> fieldPath)
    <|> (Syntax.StringValue . T.pack <$> stringLiteral)

-- | Two-character operators are tried first.
compOperator :: Parser CompOp
compOperator =
  choice
    [ GTE <$ try (string ">="),
      LTE <$ try (string "<="),
      NE <$ try (string "!="),
      EQ <$ char '=',
      GT <$ char '>',
      LT <$ char '<'
    ]

actionParser :: Parser Action
actionParser = compositeAction <|> singleAction
  where
    compositeAction =
      Syntax.CompositeAction
        <$> between (char '[' *> spaces) (spaces *> char ']') (sepBy1 singleAction (spaces *> char ',' *> spaces))

    singleAction =
      choice
        [ try $ stringAction "FLAG_FRAUD" Syntax.FlagFraud,
          try $ stringAction "REQUIRE_REVIEW" Syntax.RequireReview,
          try $ stringAction "REJECT" Syntax.RejectClaim,
          try $ stringAction "APPROVE" Syntax.ApproveClaim,
          Syntax.AssignRiskScore <$> (string "RISK_SCORE" *> spaces *> riskScoreLiteral)
        ]

    stringAction kwd constructor =
      constructor . T.pack <$> (string kwd *> spaces *> stringLiteral)

-- ----------------------------------------------------------------------------
-- Lexical elements
-- ----------------------------------------------------------------------------

-- | Letters, digits and underscores; may start with a digit, for X12 loop
-- IDs such as @2300@. Reserved words are rejected.
identifier :: Parser String
identifier = notReserved =<< ((:) <$> (alphaNum <|> char '_') <*> many (alphaNum <|> char '_'))

notReserved :: String -> Parser String
notReserved ident
  | ident `elem` reservedWords = fail $ "Identifier cannot be a keyword: " ++ ident
  | otherwise = pure ident

reservedWords :: [String]
reservedWords =
  [ "RULE", "WHEN", "THEN", "TRUE", "FALSE", "AND", "OR", "NOT", "WHERE",
    "EXISTS", "FORALL", "COUNT", "LET", "IS", "NULL", "BETWEEN", "IN"
  ]

-- | A double-quoted string. There are no escape sequences.
stringLiteral :: Parser String
stringLiteral = between (char '"') (char '"') (many (noneOf "\""))

intLiteral :: Parser Int
intLiteral = read <$> many1 digit

-- | RISK_SCORE is 0 to 100; anything else is a parse error.
riskScoreLiteral :: Parser Int
riskScoreLiteral = do
  n <- intLiteral
  if n < 0 || n > 100
    then fail $ "RISK_SCORE must be in range 0-100, got: " ++ show n
    else pure n

-- | @123@, @45.67@, @-5@, @-0.5@
numberLiteral :: Parser Double
numberLiteral = do
  sign <- option "" (string "-")
  intPart <- many1 digit
  fracPart <- optionMaybe (char '.' *> many1 digit)
  pure $ read $ sign ++ maybe intPart ((intPart ++ ".") ++) fracPart
