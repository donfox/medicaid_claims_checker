{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.Parser
  ( parseRule,
    parseRules,
    ParseError,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Text.Parsec
import Text.Parsec.Text
import X12.DSL.Syntax (Action, FieldRef, Predicate, Rule, SegmentPath, Value)
import X12.DSL.Syntax qualified as Syntax

-- | Parse a single rule from text
parseRule :: Text -> Either ParseError Rule
parseRule = parse ruleParser "rule"

-- | Parse multiple rules from text
parseRules :: Text -> Either ParseError [Rule]
parseRules = parse rulesParser "rules"

-- Parser combinators

-- Handle all whitespace including newlines and carriage returns
whitespace :: Parser ()
whitespace = skipMany (oneOf " \t\n\r")

-- Match a keyword with word boundary
keyword :: String -> Parser ()
keyword kw = try (string kw >> notFollowedBy (alphaNum <|> char '_'))

rulesParser :: Parser [Rule]
rulesParser = do
  whitespace
  rules <- many ruleParser
  eof
  return rules

ruleParser :: Parser Rule
ruleParser = do
  whitespace
  keyword "RULE"
  whitespace
  name <- identifier
  whitespace
  -- Support both: "description" or DESCRIPTION "description"
  desc <- descriptionPart
  whitespace
  keyword "WHEN"
  whitespace
  cond <- predicateParser
  whitespace
  keyword "THEN"
  whitespace
  act <- actionParser
  whitespace
  -- Support both: ; or END
  _ <- (char ';' >> return ()) <|> keyword "END"
  whitespace
  return $ Syntax.Rule (T.pack name) (T.pack desc) cond act

-- Parse description: either direct string literal or DESCRIPTION keyword followed by string
descriptionPart :: Parser String
descriptionPart = try withKeyword <|> stringLiteral
  where
    withKeyword = do
      keyword "DESCRIPTION"
      whitespace
      stringLiteral

predicateParser :: Parser Predicate
predicateParser = try orExpr

orExpr :: Parser Predicate
orExpr = do
  left <- andExpr
  rest <- optionMaybe (try (whitespace >> keyword "OR" >> whitespace >> orExpr))
  case rest of
    Nothing -> return left
    Just right -> return $ Syntax.Or left right

andExpr :: Parser Predicate
andExpr = do
  left <- notExpr
  rest <- optionMaybe (try (whitespace >> keyword "AND" >> whitespace >> andExpr))
  case rest of
    Nothing -> return left
    Just right -> return $ Syntax.And left right

notExpr :: Parser Predicate
notExpr =
  ( do
      keyword "NOT"
      whitespace
      pred <- atomicPredicate
      return $ Syntax.Not pred
  )
    <|> atomicPredicate

atomicPredicate :: Parser Predicate
atomicPredicate =
  try existsPred
    <|> try forAllPred
    <|> try countPred
    <|> try comparisonPred
    <|> try nullCheckPred
    <|> parenPredicate
    <|> boolLiteral

parenPredicate :: Parser Predicate
parenPredicate = do
  _ <- char '('
  spaces
  pred <- predicateParser
  spaces
  _ <- char ')'
  return pred

existsPred :: Parser Predicate
existsPred = do
  _ <- string "EXISTS"
  spaces
  path <- segmentPath
  spaces
  _ <- string "WHERE"
  spaces
  pred <- predicateParser
  return $ Syntax.Exists path pred

forAllPred :: Parser Predicate
forAllPred = do
  _ <- string "FORALL"
  spaces
  path <- segmentPath
  spaces
  _ <- string "WHERE"
  spaces
  pred <- predicateParser
  return $ Syntax.ForAll path pred

countPred :: Parser Predicate
countPred = do
  _ <- string "COUNT"
  spaces
  _ <- char '('
  spaces
  path <- segmentPath
  spaces
  _ <- char ')'
  spaces
  op <- compOperator
  spaces
  n <- intLiteral
  return $ Syntax.Count path op n

comparisonPred :: Parser Predicate
comparisonPred = do
  field <- fieldRef
  spaces
  op <- compOperator
  spaces
  val <- valueParser
  return $ case op of
    Syntax.EQ -> Syntax.Equals field val
    Syntax.NE -> Syntax.NotEquals field val
    Syntax.GT -> Syntax.GreaterThan field val
    Syntax.LT -> Syntax.LessThan field val
    Syntax.GTE -> Syntax.GreaterThanOrEqual field val
    Syntax.LTE -> Syntax.LessThanOrEqual field val

nullCheckPred :: Parser Predicate
nullCheckPred = do
  field <- fieldRef
  spaces
  _ <- string "IS"
  spaces
  nullCheck <-
    (string "NOT NULL" >> return Syntax.IsNotNull)
      <|> (string "NULL" >> return Syntax.IsNull)
  return $ nullCheck field

boolLiteral :: Parser Predicate
boolLiteral =
  (keyword "TRUE" >> return Syntax.PTrue)
    <|> (keyword "FALSE" >> return Syntax.PFalse)

segmentPath :: Parser SegmentPath
segmentPath = do
  loop <- identifier
  segs <-
    option
      []
      ( do
          _ <- char '.'
          sepBy1 identifier (char '.')
      )
  return $ Syntax.SegmentPath (T.pack loop) (map T.pack segs)

fieldRef :: Parser FieldRef
fieldRef = try loopField <|> try segmentField <|> simpleField
  where
    simpleField = Syntax.Field . T.pack <$> identifier
    segmentField = do
      seg <- identifier
      _ <- char '.'
      field <- identifier
      return $ Syntax.SegmentField (T.pack seg) (T.pack field)
    loopField = do
      loop <- identifier
      _ <- char '.'
      seg <- identifier
      _ <- char '.'
      field <- identifier
      return $ Syntax.LoopField (T.pack loop) (T.pack seg) (T.pack field)

valueParser :: Parser Value
valueParser =
  try (Syntax.NumberValue <$> numberLiteral)
    <|> (Syntax.StringValue . T.pack <$> stringLiteral)

compOperator :: Parser Syntax.CompOp
compOperator =
  try (string ">=" >> return Syntax.GTE)
    <|> try (string "<=" >> return Syntax.LTE)
    <|> try (string "!=" >> return Syntax.NE)
    <|> (char '=' >> return Syntax.EQ)
    <|> (char '>' >> return Syntax.GT)
    <|> (char '<' >> return Syntax.LT)

actionParser :: Parser Action
actionParser = compositeAction <|> singleAction
  where
    compositeAction = do
      _ <- char '['
      spaces
      actions <- sepBy1 singleAction (spaces >> char ',' >> spaces)
      spaces
      _ <- char ']'
      return $ Syntax.CompositeAction actions

    singleAction =
      try flagFraud
        <|> try riskScore
        <|> try requireReview
        <|> rejectClaim

    flagFraud = do
      _ <- string "FLAG_FRAUD"
      spaces
      reason <- stringLiteral
      return $ Syntax.FlagFraud (T.pack reason)

    riskScore = do
      _ <- string "RISK_SCORE"
      spaces
      score <- intLiteral
      return $ Syntax.AssignRiskScore score

    requireReview = do
      _ <- string "REQUIRE_REVIEW"
      spaces
      note <- stringLiteral
      return $ Syntax.RequireReview (T.pack note)

    rejectClaim = do
      _ <- string "REJECT"
      spaces
      reason <- stringLiteral
      return $ Syntax.RejectClaim (T.pack reason)

-- Lexical elements

identifier :: Parser String
identifier = do
  -- allow loop/segment identifiers that start with digits (e.g., 2300)
  first <- alphaNum <|> char '_'
  rest <- many (alphaNum <|> char '_')
  let ident = first : rest
  -- reject reserved keywords
  if ident `elem` ["RULE", "WHEN", "THEN", "TRUE", "FALSE", "AND", "OR", "NOT", "WHERE", "EXISTS", "FORALL", "COUNT", "IS", "NULL"]
    then fail $ "Identifier cannot be a keyword: " ++ ident
    else return ident

stringLiteral :: Parser String
stringLiteral = between (char '"') (char '"') (many (noneOf "\""))

intLiteral :: Parser Int
intLiteral = read <$> many1 digit

numberLiteral :: Parser Double
numberLiteral = do
  intPart <- many1 digit
  fracPart <- optionMaybe (char '.' >> many1 digit)
  return $ case fracPart of
    Nothing -> read intPart
    Just frac -> read (intPart ++ "." ++ frac)
