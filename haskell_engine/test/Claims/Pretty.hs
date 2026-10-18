{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.Pretty
-- Description : Render rule ASTs back to DSL text
-- Stability   : experimental
--
-- The inverse of "Claims.Parser". Its defining property, checked by
-- QuickCheck in the test suite, is the round trip
--
-- @
-- parseRule (prettyRule r) == Right r
-- @
--
-- for every rule @r@ the parser can produce. The test suite uses it as the
-- oracle for that property.
--
-- A few AST values have no DSL syntax and so cannot round-trip: strings
-- containing a double quote (the DSL has no escapes), non-finite numbers,
-- and nested 'CompositeAction's. The parser never produces any of these.
--
-- ==== Example
--
-- >>> T.putStrLn (prettyRule rule)
-- RULE high_amount "Flag claims over $10,000"
--   WHEN CLM.amount > 10000
--   THEN FLAG_FRAUD "Unusually high claim amount";
module Claims.Pretty
  ( prettyRules,
    prettyRule,
  )
where

import Prelude hiding (EQ, GT, LT)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showFFloat)
import Claims.Syntax

-- | Render a rule set, one blank line between rules.
prettyRules :: [Rule] -> Text
prettyRules = T.intercalate "\n\n" . map prettyRule

-- | Render one rule, with @LET@, @WHEN@ and @THEN@ on their own lines.
prettyRule :: Rule -> Text
prettyRule rule =
  T.intercalate "\n" $
    ["RULE " <> ruleName rule <> " " <> quoted (ruleDescription rule)]
      ++ map (("  " <>) . prettyBinding) (ruleBindings rule)
      ++ [ "  WHEN " <> prettyPredicate (ruleCondition rule),
           "  THEN " <> prettyAction (ruleAction rule) <> ";"
         ]

prettyBinding :: Binding -> Text
prettyBinding (Binding name ref) = "LET " <> name <> " = " <> prettyPath ref

-- | Render a predicate.
--
-- Every operand of @AND@ / @OR@ and every @NOT@ / @WHERE@ body is
-- parenthesised, so the output never depends on operator precedence.
prettyPredicate :: Predicate -> Text
prettyPredicate = \case
  PTrue -> "TRUE"
  PFalse -> "FALSE"
  Compare op f v -> prettyPath f <> " " <> prettyCompOp op <> " " <> prettyValue v
  Contains f v -> prettyPath f <> " CONTAINS " <> prettyValue v
  Matches f pattern -> prettyPath f <> " MATCHES " <> quoted pattern
  IsNull f -> prettyPath f <> " IS NULL"
  IsNotNull f -> prettyPath f <> " IS NOT NULL"
  And p q -> parens p <> " AND " <> parens q
  Or p q -> parens p <> " OR " <> parens q
  Not p -> "NOT " <> parens p
  Between f lo hi ->
    prettyPath f <> " BETWEEN " <> prettyValue lo <> " AND " <> prettyValue hi
  HasDiagnosis v -> "claim.has_diagnosis " <> prettyValue v
  HasProcedure v -> "claim.has_procedure " <> prettyValue v
  Exists var path p -> quantifier "EXISTS" var path p
  ForAll var path p -> quantifier "FORALL" var path p
  Count path op n ->
    "COUNT(" <> prettyPath path <> ") " <> prettyCompOp op <> " " <> T.pack (show n)
  HelperCall name args ->
    name <> "(" <> T.intercalate ", " (map prettyValue args) <> ")"
  where
    parens p = "(" <> prettyPredicate p <> ")"
    quantifier kwd var path p =
      kwd <> " " <> maybe "" (<> " IN ") var <> prettyPath path <> " WHERE " <> parens p

-- | Render an action; a 'CompositeAction' becomes a bracketed list.
prettyAction :: Action -> Text
prettyAction = \case
  FlagFraud reason -> "FLAG_FRAUD " <> quoted reason
  AssignRiskScore n -> "RISK_SCORE " <> T.pack (show n)
  RequireReview note -> "REQUIRE_REVIEW " <> quoted note
  RejectClaim reason -> "REJECT " <> quoted reason
  ApproveClaim reason -> "APPROVE " <> quoted reason
  CompositeAction acts -> "[" <> T.intercalate ", " (map prettyAction acts) <> "]"

-- | Render a literal value.
prettyValue :: Value -> Text
prettyValue = \case
  StringValue t -> quoted t
  NumberValue n -> prettyNumber n
  ListValue vs -> "[" <> T.intercalate ", " (map prettyValue vs) <> "]"
  FieldValue ref -> prettyPath ref

-- | Plain decimal notation, never scientific (the parser does not read
-- @1.0e-3@). Whole numbers drop the fractional part: @10000@, not @10000.0@.
prettyNumber :: Double -> Text
prettyNumber n
  | n == fromIntegral whole && abs n < 1e15 = T.pack (show whole)
  | otherwise = T.pack (showFFloat Nothing n "")
  where
    whole = round n :: Integer

prettyPath :: Path -> Text
prettyPath (Path parts) = T.intercalate "." parts

prettyCompOp :: CompOp -> Text
prettyCompOp = \case
  EQ -> "="
  NE -> "!="
  GT -> ">"
  LT -> "<"
  GTE -> ">="
  LTE -> "<="

quoted :: Text -> Text
quoted t = "\"" <> t <> "\""
