{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : X12.DSL.SimpleEvaluator
Description : Evaluate DSL predicates against generic JSON documents
Stability   : experimental

This module evaluates fraud detection rules against generic JSON documents
(Aeson 'Aeson.Value'). This is the recommended evaluator for production use
with JSON claim data.

Unlike "X12.DSL.Evaluator" which requires a fully parsed 'X12Document'
structure, this evaluator works with any JSON, making it suitable for:

* Flat JSON representations of claims
* JSON APIs
* Testing with simple JSON fixtures

== Field Lookup

Fields are looked up using dot notation paths:

* @"amount"@ - direct field lookup
* @"claim.amount"@ - nested field lookup
* @"items.0.price"@ - array index access

The evaluator automatically converts JSON values to text for comparison.

== Example Usage

@
import Data.Aeson (decode)
import X12.DSL.SimpleEvaluator
import X12.DSL.Parser (parseRule)

main :: IO ()
main = do
  let Just claim = decode "{\"amount\": 15000, \"status\": \"pending\"}"
      Right rule = parseRule "RULE test \"\" WHEN amount > 10000 THEN FLAG_FRAUD \"high\";"
  print $ evaluateRuleSimple claim rule
@
-}
module X12.DSL.SimpleEvaluator
  ( -- * Evaluation Functions
    evaluatePredicateSimple
  , evaluateRuleSimple
    -- * Field Lookup (exported for testing)
  , lookupJsonField
  ) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (isJust, isNothing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import X12.DSL.Syntax qualified as Syntax
import X12.DSL.X12Types (Action' (..), RuleResult (..))

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

-- | Evaluate a predicate against a JSON value.
--
-- Returns 'True' if the predicate matches the JSON document, 'False' otherwise.
--
-- ==== Example
--
-- @
-- let doc = Aeson.object ["amount" .= (15000 :: Int)]
--     pred = Syntax.GreaterThan (Syntax.Field "amount") (Syntax.NumberValue 10000)
-- evaluatePredicateSimple doc pred  -- Returns True
-- @
evaluatePredicateSimple :: Aeson.Value -> Syntax.Predicate -> Bool
evaluatePredicateSimple doc = \case
  -- Boolean literals
  Syntax.PTrue  -> True
  Syntax.PFalse -> False

  -- Equality comparisons
  Syntax.Equals fieldRef val ->
    compareField fieldRef val (==) doc
  Syntax.NotEquals fieldRef val ->
    compareField fieldRef val (/=) doc

  -- Numeric comparisons
  Syntax.GreaterThan fieldRef val ->
    compareNumericField fieldRef val (>) doc
  Syntax.LessThan fieldRef val ->
    compareNumericField fieldRef val (<) doc
  Syntax.GreaterThanOrEqual fieldRef val ->
    compareNumericField fieldRef val (>=) doc
  Syntax.LessThanOrEqual fieldRef val ->
    compareNumericField fieldRef val (<=) doc

  -- Null checks
  Syntax.IsNull fieldRef ->
    isNothing $ lookupJsonField fieldRef doc
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupJsonField fieldRef doc

  -- Boolean logic (recursive)
  Syntax.And p1 p2 ->
    evaluatePredicateSimple doc p1 && evaluatePredicateSimple doc p2
  Syntax.Or p1 p2 ->
    evaluatePredicateSimple doc p1 || evaluatePredicateSimple doc p2
  Syntax.Not p ->
    not $ evaluatePredicateSimple doc p

  -- Quantifiers over arrays
  Syntax.Exists path innerPred ->
    any (`evaluatePredicateSimple` innerPred) (findArrayItems path doc)
  Syntax.ForAll path innerPred ->
    all (`evaluatePredicateSimple` innerPred) (findArrayItems path doc)
  Syntax.Count path op n ->
    compareInt (length $ findArrayItems path doc) op n

  -- String operations
  Syntax.Contains fieldRef val ->
    case (lookupJsonField fieldRef doc, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    False  -- TODO: Implement regex matching

-- | Evaluate a complete rule against a JSON document.
--
-- Returns a 'RuleResult' indicating whether the rule matched and what
-- action should be taken.
evaluateRuleSimple :: Aeson.Value -> Syntax.Rule -> RuleResult
evaluateRuleSimple doc rule =
  let matched = evaluatePredicateSimple doc (Syntax.ruleCondition rule)
      action  = if matched
                then Just (convertAction $ Syntax.ruleAction rule)
                else Nothing
      details = if matched
                then "Rule matched: " <> Syntax.ruleDescription rule
                else "Rule did not match"
  in RuleResult
       { resultRuleName = Syntax.ruleName rule
       , resultMatched  = matched
       , resultAction   = action
       , resultDetails  = details
       }

-- ----------------------------------------------------------------------------
-- Field Comparison Helpers
-- ----------------------------------------------------------------------------

-- | Compare a field's string value against an expected value.
compareField
  :: Syntax.FieldRef
  -> Syntax.Value
  -> (Text -> Text -> Bool)
  -> Aeson.Value
  -> Bool
compareField fieldRef val cmp doc =
  case (lookupJsonField fieldRef doc, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) -> cmp fieldVal expectedVal
    _ -> False

-- | Compare a field's numeric value against an expected value.
compareNumericField
  :: Syntax.FieldRef
  -> Syntax.Value
  -> (Double -> Double -> Bool)
  -> Aeson.Value
  -> Bool
compareNumericField fieldRef val cmp doc =
  case (lookupJsonField fieldRef doc, val) of
    (Just fieldVal, Syntax.NumberValue expectedVal) ->
      case textToDouble fieldVal of
        Just actualVal -> cmp actualVal expectedVal
        Nothing        -> False
    _ -> False

-- | Compare two integers using a comparison operator.
compareInt :: Int -> Syntax.CompOp -> Int -> Bool
compareInt actual op expected = case op of
  Syntax.EQ  -> actual == expected
  Syntax.NE  -> actual /= expected
  Syntax.GT  -> actual >  expected
  Syntax.LT  -> actual <  expected
  Syntax.GTE -> actual >= expected
  Syntax.LTE -> actual <= expected

-- | Parse a Text value as a Double.
textToDouble :: Text -> Maybe Double
textToDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _         -> Nothing

-- ----------------------------------------------------------------------------
-- JSON Field Lookup
-- ----------------------------------------------------------------------------

-- | Look up a field in a JSON value using dot notation.
--
-- Supports multiple reference styles:
--
-- * @Field "amount"@ → looks up @"amount"@ directly
-- * @Field "claim.amount"@ → looks up @claim.amount@ (dot-separated path)
-- * @SegmentField "CLM" "amount"@ → looks up @CLM.amount@
-- * @LoopField "2300" "CLM" "01"@ → looks up @2300.CLM.01@
--
-- Array indices are supported: @"items.0.price"@ accesses the first item's price.
lookupJsonField :: Syntax.FieldRef -> Aeson.Value -> Maybe Text
lookupJsonField fieldRef doc = case fieldRef of
  Syntax.Field name ->
    lookupPath (T.splitOn "." name) doc

  Syntax.SegmentField seg field ->
    lookupPath [seg, field] doc

  Syntax.LoopField loop seg field ->
    lookupPath [loop, seg, field] doc

  Syntax.ElementPosition _ _ _ ->
    Nothing  -- Not used for JSON

-- | Navigate a dot-separated path through JSON and extract a text value.
--
-- Handles both objects (by key) and arrays (by numeric index).
lookupPath :: [Text] -> Aeson.Value -> Maybe Text
lookupPath []           val = valueToText val
lookupPath (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPath rest

  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")] | idx >= 0 && idx < V.length arr ->
        lookupPath rest (arr V.! idx)
      _ -> Nothing

  _ -> Nothing

-- | Convert a JSON value to Text for comparison.
--
-- * Strings are returned as-is
-- * Numbers are converted to decimal text
-- * Booleans become "true" or "false"
-- * Null and complex types (arrays, objects) return 'Nothing'
valueToText :: Aeson.Value -> Maybe Text
valueToText = \case
  Aeson.String t  -> Just t
  Aeson.Number n  -> Just $ T.pack $ show (toRealFloat n :: Double)
  Aeson.Bool True -> Just "true"
  Aeson.Bool False -> Just "false"
  Aeson.Null      -> Nothing
  _               -> Nothing  -- Arrays and objects can't be compared as text

-- ----------------------------------------------------------------------------
-- Array Navigation for Quantifiers
-- ----------------------------------------------------------------------------

-- | Find array items at a path for EXISTS/FORALL/COUNT predicates.
--
-- If the path points to an array, returns its elements.
-- If the path points to an object, returns it as a single-element list.
-- Otherwise returns an empty list.
findArrayItems :: Syntax.SegmentPath -> Aeson.Value -> [Aeson.Value]
findArrayItems (Syntax.SegmentPath pathStr _) doc =
  case lookupPathRaw (T.splitOn "." pathStr) doc of
    Just (Aeson.Array arr)    -> V.toList arr
    Just obj@(Aeson.Object _) -> [obj]  -- Single object as list of one
    _                         -> []

-- | Navigate a path but return the raw JSON value (not converted to text).
lookupPathRaw :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPathRaw []           val = Just val
lookupPathRaw (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPathRaw rest

  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")] | idx >= 0 && idx < V.length arr ->
        lookupPathRaw rest (arr V.! idx)
      _ -> Nothing

  _ -> Nothing

-- ----------------------------------------------------------------------------
-- Action Conversion
-- ----------------------------------------------------------------------------

-- | Convert a Syntax.Action to Action' for inclusion in results.
convertAction :: Syntax.Action -> Action'
convertAction = \case
  Syntax.FlagFraud reason       -> FlagFraud' reason
  Syntax.AssignRiskScore score  -> AssignRiskScore' score
  Syntax.RequireReview note     -> RequireReview' note
  Syntax.RejectClaim reason     -> RejectClaim' reason
  Syntax.CompositeAction actions -> CompositeAction' (map convertAction actions)
