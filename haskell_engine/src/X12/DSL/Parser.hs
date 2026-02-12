{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : X12.DSL.Parser
Description : Parsec-based parser for the X12 fraud detection DSL
Stability   : experimental

This module provides a parser for the fraud detection domain-specific language (DSL).
Rules are parsed from text into an abstract syntax tree (AST) defined in "X12.DSL.Syntax".

== Grammar Overview

The DSL follows this structure:

@
RULE \<name\> \<description\>
WHEN \<predicate\>
THEN \<action\>;
@

Where:

* @\<name\>@ is an identifier (alphanumeric, may start with digit for X12 loop IDs like @2300@)
* @\<description\>@ is a quoted string, optionally preceded by @DESCRIPTION@ keyword
* @\<predicate\>@ is a boolean expression (see below)
* @\<action\>@ is one of: @FLAG_FRAUD@, @RISK_SCORE@, @REQUIRE_REVIEW@, @REJECT@
* Rules can end with @;@ or @END@

== Predicate Syntax

Predicates support:

* __Comparisons__: @field = value@, @field != value@, @field > value@, @field < value@, @field >= value@, @field <= value@
* __Null checks__: @field IS NULL@, @field IS NOT NULL@
* __Boolean logic__: @AND@, @OR@, @NOT@, parentheses for grouping
* __Quantifiers__: @EXISTS path WHERE predicate@, @FORALL path WHERE predicate@
* __Counting__: @COUNT(path) > n@

== Field References

Fields can be referenced in three ways:

* Simple: @amount@ (direct field name)
* Segment-qualified: @CLM.amount@ (segment.field)
* Loop-qualified: @2300.CLM.amount@ (loop.segment.field)

== Example Rules

@
-- Flag high-value claims
RULE high_amount "Flag claims over $10,000"
WHEN CLM.amount > 10000
THEN FLAG_FRAUD "Unusually high claim amount";

-- Require review for specific providers
RULE provider_check "Review claims from flagged providers"
WHEN provider_npi = "1234567890" AND claim_status != "denied"
THEN REQUIRE_REVIEW "Provider under investigation";

-- Multiple actions
RULE complex_rule "Multiple fraud indicators"
WHEN amount > 5000 AND COUNT(2400.SV1) > 10
THEN [FLAG_FRAUD "Multiple indicators", RISK_SCORE 85];
@

== Usage

@
import X12.DSL.Parser
import qualified Data.Text as T

main :: IO ()
main = do
    let ruleText = T.pack "RULE test \"A test rule\" WHEN amount > 100 THEN FLAG_FRAUD \"High amount\";"
    case parseRule ruleText of
        Left err   -> putStrLn $ "Parse error: " ++ show err
        Right rule -> print rule
@
-}
module X12.DSL.Parser
  ( -- * Parsing Functions
    parseRule,
    parseRules,
    -- * Error Type
    ParseError,
  )
where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Text qualified as T
import Text.Parsec hiding ((<|>))
import Text.Parsec.Text
import X12.DSL.Syntax (Action, FieldRef, Predicate, Rule, SegmentPath, Value)
import X12.DSL.Syntax qualified as Syntax

-- ----------------------------------------------------------------------------
-- Exported Parsing Functions
-- ----------------------------------------------------------------------------

-- | Parse a single rule from text.
--
-- Returns 'Left' with a 'ParseError' if parsing fails, or 'Right' with
-- the parsed 'Rule' on success.
--
-- ==== Example
--
-- @
-- >>> parseRule "RULE test \"desc\" WHEN x > 1 THEN FLAG_FRAUD \"reason\";"
-- Right (Rule {ruleName = "test", ...})
-- @
parseRule :: Text -> Either ParseError Rule
parseRule = parse ruleParser "rule"

-- | Parse multiple rules from text.
--
-- Parses zero or more rules separated by whitespace. The input must be
-- completely consumed (no trailing content after the last rule).
--
-- ==== Example
--
-- @
-- >>> parseRules "RULE r1 \"d1\" WHEN TRUE THEN RISK_SCORE 50; RULE r2 \"d2\" WHEN FALSE THEN REJECT \"no\";"
-- Right [Rule {...}, Rule {...}]
-- @
parseRules :: Text -> Either ParseError [Rule]
parseRules = parse rulesParser "rules"

-- ----------------------------------------------------------------------------
-- Lexical Helpers
-- ----------------------------------------------------------------------------

-- | Skip whitespace characters including spaces, tabs, and newlines.
whitespace :: Parser ()
whitespace = skipMany (oneOf " \t\n\r")

-- | Match a keyword ensuring it's not part of a larger identifier.
--
-- Uses word boundary detection to prevent matching "ANDROID" when looking for "AND".
keyword :: String -> Parser ()
keyword s = try $ string s *> notFollowedBy (alphaNum <|> char '_')

-- | Lexeme parser: parse something followed by whitespace.
lexeme :: Parser a -> Parser a
lexeme p = p <* whitespace

-- | Parse a keyword as a lexeme (keyword + whitespace).
kw :: String -> Parser ()
kw = lexeme . keyword

-- ----------------------------------------------------------------------------
-- Rule Parsers
-- ----------------------------------------------------------------------------

-- | Parse zero or more rules, consuming all input.
rulesParser :: Parser [Rule]
rulesParser = whitespace *> many ruleParser <* eof

-- | Parse a single rule.
--
-- Grammar:
--
-- @
-- rule ::= RULE identifier description WHEN predicate THEN action terminator
-- terminator ::= ';' | END
-- @
ruleParser :: Parser Rule
ruleParser = do
  kw "RULE"
  name <- lexeme identifier
  desc <- lexeme descriptionPart
  kw "WHEN"
  cond <- lexeme predicateParser
  kw "THEN"
  act <- lexeme actionParser
  lexeme (char ';' $> () <|> keyword "END")
  pure $ Syntax.Rule (T.pack name) (T.pack desc) cond act

-- | Parse rule description: either a direct string literal or @DESCRIPTION "..."@.
descriptionPart :: Parser String
descriptionPart = try (kw "DESCRIPTION" *> stringLiteral) <|> stringLiteral

-- ----------------------------------------------------------------------------
-- Predicate Parsers
-- ----------------------------------------------------------------------------
-- Operator precedence (lowest to highest):
--   1. OR
--   2. AND
--   3. NOT
--   4. Atomic predicates (comparisons, quantifiers, etc.)

-- | Top-level predicate parser. Entry point for parsing boolean expressions.
predicateParser :: Parser Predicate
predicateParser = orExpr

-- | Parse OR expressions (lowest precedence).
--
-- @pred1 OR pred2 OR pred3@ is parsed as @Or pred1 (Or pred2 pred3)@ (right-associative).
orExpr :: Parser Predicate
orExpr = chainr1 andExpr (Syntax.Or <$ try (whitespace *> kw "OR"))

-- | Parse AND expressions (higher precedence than OR).
--
-- @pred1 AND pred2 AND pred3@ is parsed as @And pred1 (And pred2 pred3)@ (right-associative).
andExpr :: Parser Predicate
andExpr = chainr1 notExpr (Syntax.And <$ try (whitespace *> kw "AND"))

-- | Parse NOT expressions (higher precedence than AND).
--
-- @NOT predicate@ negates the following atomic predicate.
notExpr :: Parser Predicate
notExpr = (Syntax.Not <$> (kw "NOT" *> atomicPredicate)) <|> atomicPredicate

-- | Parse atomic predicates (highest precedence).
--
-- Atomic predicates are the building blocks that cannot be further decomposed
-- by boolean operators. Includes quantifiers, comparisons, null checks,
-- parenthesized expressions, and boolean literals.
atomicPredicate :: Parser Predicate
atomicPredicate =
  choice
    [ try existsPred
    , try forAllPred
    , try countPred
    , try comparisonPred
    , try nullCheckPred
    , parenPredicate
    , boolLiteral
    ]

-- | Parse parenthesized predicate for explicit grouping.
--
-- @(pred1 OR pred2) AND pred3@ allows OR to bind tighter than AND.
parenPredicate :: Parser Predicate
parenPredicate = between (char '(' *> spaces) (spaces *> char ')') predicateParser

-- | Parse existential quantifier.
--
-- @EXISTS path WHERE predicate@ - true if any item in path satisfies predicate.
--
-- Example: @EXISTS 2400 WHERE SV1.amount > 1000@
existsPred :: Parser Predicate
existsPred =
  Syntax.Exists
    <$> (string "EXISTS" *> spaces *> segmentPath)
    <*> (spaces *> string "WHERE" *> spaces *> predicateParser)

-- | Parse universal quantifier.
--
-- @FORALL path WHERE predicate@ - true if all items in path satisfy predicate.
--
-- Example: @FORALL 2400.SV1 WHERE amount < 5000@
forAllPred :: Parser Predicate
forAllPred =
  Syntax.ForAll
    <$> (string "FORALL" *> spaces *> segmentPath)
    <*> (spaces *> string "WHERE" *> spaces *> predicateParser)

-- | Parse count predicate.
--
-- @COUNT(path) op n@ - compare the number of items at path against n.
--
-- Example: @COUNT(2400) > 10@ (more than 10 service lines)
countPred :: Parser Predicate
countPred =
  Syntax.Count
    <$> (string "COUNT" *> spaces *> between (char '(') (char ')') (spaces *> segmentPath <* spaces))
    <*> (spaces *> compOperator)
    <*> (spaces *> intLiteral)

-- | Parse comparison predicate.
--
-- @field op value@ where op is one of: @=@, @!=@, @>@, @<@, @>=@, @<=@
--
-- Example: @CLM.amount > 10000@
comparisonPred :: Parser Predicate
comparisonPred = do
  field <- fieldRef
  spaces
  op <- compOperator
  spaces
  val <- valueParser
  pure $ opToPredicate op field val
  where
    opToPredicate Syntax.EQ  = Syntax.Equals
    opToPredicate Syntax.NE  = Syntax.NotEquals
    opToPredicate Syntax.GT  = Syntax.GreaterThan
    opToPredicate Syntax.LT  = Syntax.LessThan
    opToPredicate Syntax.GTE = Syntax.GreaterThanOrEqual
    opToPredicate Syntax.LTE = Syntax.LessThanOrEqual

-- | Parse null check predicate.
--
-- @field IS NULL@ or @field IS NOT NULL@
nullCheckPred :: Parser Predicate
nullCheckPred = do
  field <- fieldRef <* spaces <* string "IS" <* spaces
  nullCheck <- (Syntax.IsNotNull <$ string "NOT NULL") <|> (Syntax.IsNull <$ string "NULL")
  pure $ nullCheck field

-- | Parse boolean literals: @TRUE@ or @FALSE@.
boolLiteral :: Parser Predicate
boolLiteral = (Syntax.PTrue <$ keyword "TRUE") <|> (Syntax.PFalse <$ keyword "FALSE")

-- ----------------------------------------------------------------------------
-- Path and Field Reference Parsers
-- ----------------------------------------------------------------------------

-- | Parse a segment path for quantified predicates.
--
-- Paths identify a location in the X12 document hierarchy:
--
-- * @2300@ - just a loop ID
-- * @2300.CLM@ - loop with segment
-- * @2400.SV1.amount@ - loop, segment, and field
segmentPath :: Parser SegmentPath
segmentPath =
  Syntax.SegmentPath
    <$> (T.pack <$> identifier)
    <*> option [] (char '.' *> (map T.pack <$> sepBy1 identifier (char '.')))

-- | Parse a field reference.
--
-- Field references identify a specific value in the document:
--
-- * __Simple__: @amount@ - direct field name lookup
-- * __Segment-qualified__: @CLM.amount@ - field within a segment
-- * __Loop-qualified__: @2300.CLM.amount@ - field within a segment within a loop
--
-- The parser tries the most specific (loop-qualified) first, then falls back
-- to less specific forms.
fieldRef :: Parser FieldRef
fieldRef = try loopField <|> try segmentField <|> simpleField
  where
    simpleField = Syntax.Field . T.pack <$> identifier

    segmentField =
      Syntax.SegmentField
        <$> (T.pack <$> identifier <* char '.')
        <*> (T.pack <$> identifier)

    loopField =
      Syntax.LoopField
        <$> (T.pack <$> identifier <* char '.')
        <*> (T.pack <$> identifier <* char '.')
        <*> (T.pack <$> identifier)

-- ----------------------------------------------------------------------------
-- Value and Operator Parsers
-- ----------------------------------------------------------------------------

-- | Parse a literal value (number, string, or field reference).
--
-- * Numbers: @123@, @45.67@
-- * Strings: @"hello world"@
-- * Field refs: @2300.CLM.01@ (for field-to-field comparisons)
valueParser :: Parser Value
valueParser =
  try (Syntax.NumberValue <$> numberLiteral)
    <|> try (Syntax.FieldRefValue <$> fieldRef)
    <|> (Syntax.StringValue . T.pack <$> stringLiteral)

-- | Parse a comparison operator.
--
-- Supported operators:
--
-- * @=@ (equals)
-- * @!=@ (not equals)
-- * @>@ (greater than)
-- * @<@ (less than)
-- * @>=@ (greater than or equal)
-- * @<=@ (less than or equal)
--
-- Note: Multi-character operators (@>=@, @<=@, @!=@) are tried first to avoid
-- partial matches.
compOperator :: Parser Syntax.CompOp
compOperator =
  choice
    [ Syntax.GTE <$ try (string ">=")
    , Syntax.LTE <$ try (string "<=")
    , Syntax.NE  <$ try (string "!=")
    , Syntax.EQ  <$ char '='
    , Syntax.GT  <$ char '>'
    , Syntax.LT  <$ char '<'
    ]

-- ----------------------------------------------------------------------------
-- Action Parsers
-- ----------------------------------------------------------------------------

-- | Parse an action to execute when a rule matches.
--
-- Supports single actions or composite (multiple) actions:
--
-- * @FLAG_FRAUD "reason"@ - flag the claim as potentially fraudulent
-- * @RISK_SCORE 85@ - assign a risk score (0-100)
-- * @REQUIRE_REVIEW "note"@ - flag for manual review
-- * @REJECT "reason"@ - reject the claim
-- * @[action1, action2, ...]@ - execute multiple actions
actionParser :: Parser Action
actionParser = compositeAction <|> singleAction
  where
    compositeAction =
      Syntax.CompositeAction
        <$> between (char '[' *> spaces) (spaces *> char ']') (sepBy1 singleAction (spaces *> char ',' *> spaces))

    singleAction =
      choice
        [ try $ stringAction "FLAG_FRAUD" Syntax.FlagFraud
        , try $ stringAction "REQUIRE_REVIEW" Syntax.RequireReview
        , try $ stringAction "REJECT" Syntax.RejectClaim
        , Syntax.AssignRiskScore <$> (string "RISK_SCORE" *> spaces *> intLiteral)
        ]

    -- Helper for actions that take a string argument
    stringAction :: String -> (Text -> Action) -> Parser Action
    stringAction kwd constructor =
      constructor . T.pack <$> (string kwd *> spaces *> stringLiteral)

-- ----------------------------------------------------------------------------
-- Lexical Elements
-- ----------------------------------------------------------------------------

-- | Parse an identifier.
--
-- Identifiers can contain alphanumeric characters and underscores. Unlike many
-- languages, identifiers /may/ start with a digit to support X12 loop IDs
-- like @2300@ or @2400@.
--
-- Reserved keywords cannot be used as identifiers:
-- @RULE@, @WHEN@, @THEN@, @TRUE@, @FALSE@, @AND@, @OR@, @NOT@, @WHERE@,
-- @EXISTS@, @FORALL@, @COUNT@, @IS@, @NULL@
identifier :: Parser String
identifier = do
  ident <- (:) <$> (alphaNum <|> char '_') <*> many (alphaNum <|> char '_')
  if ident `elem` reservedKeywords
    then fail $ "Identifier cannot be a keyword: " ++ ident
    else pure ident
  where
    reservedKeywords =
      [ "RULE", "WHEN", "THEN", "TRUE", "FALSE"
      , "AND", "OR", "NOT", "WHERE"
      , "EXISTS", "FORALL", "COUNT", "IS", "NULL"
      ]

-- | Parse a double-quoted string literal.
--
-- Example: @"hello world"@ parses to @"hello world"@
--
-- Note: Does not currently support escape sequences.
stringLiteral :: Parser String
stringLiteral = between (char '"') (char '"') (many (noneOf "\""))

-- | Parse an integer literal.
--
-- Example: @123@ parses to @123@
intLiteral :: Parser Int
intLiteral = read <$> many1 digit

-- | Parse a floating-point number literal.
--
-- Supports both integer and decimal formats:
--
-- * @123@ parses to @123.0@
-- * @45.67@ parses to @45.67@
numberLiteral :: Parser Double
numberLiteral = do
  intPart <- many1 digit
  fracPart <- optionMaybe (char '.' *> many1 digit)
  pure $ read $ maybe intPart ((intPart ++ ".") ++) fracPart

-- ----------------------------------------------------------------------------
-- Utilities
-- ----------------------------------------------------------------------------

-- | Replace a parser's result with a constant value.
-- (Re-exported from Data.Functor in base >= 4.7, but defined here for compatibility)
($>) :: Functor f => f a -> b -> f b
($>) = flip (<$)
infixl 4 $>
