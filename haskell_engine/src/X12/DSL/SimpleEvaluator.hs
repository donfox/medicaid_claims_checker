{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : X12.DSL.SimpleEvaluator
-- Description : Evaluate DSL predicates against generic JSON documents
-- Stability   : experimental
--
-- This module evaluates fraud detection rules against generic JSON documents
-- (Aeson 'Aeson.Value'). This is the recommended evaluator for production use
-- with JSON claim data.
--
-- Unlike "X12.DSL.Evaluator" which requires a fully parsed 'X12Document'
-- structure, this evaluator works with any JSON, making it suitable for:
--
-- * Flat JSON representations of claims
-- * JSON APIs
-- * Testing with simple JSON fixtures
--
-- == Field Lookup
--
-- Fields are looked up using dot notation paths:
--
-- * @"amount"@ - direct field lookup
-- * @"claim.amount"@ - nested field lookup
-- * @"items.0.price"@ - array index access
--
-- The evaluator automatically converts JSON values to text for comparison.
--
-- == Example Usage
--
-- @
-- import Data.Aeson (decode)
-- import X12.DSL.SimpleEvaluator
-- import X12.DSL.Parser (parseRule)
--
-- main :: IO ()
-- main = do
--   let Just claim = decode "{\"amount\": 15000, \"status\": \"pending\"}"
--       Right rule = parseRule "RULE test \"\" WHEN amount > 10000 THEN FLAG_FRAUD \"high\";"
--   print $ evaluateRuleSimple claim rule
-- @
module X12.DSL.SimpleEvaluator
  ( -- * Evaluation Functions
    evaluatePredicateSimple,
    evaluateRuleSimple,

    -- * Field Lookup (exported for testing)
    lookupJsonField,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, DayOfWeek (Saturday, Sunday), dayOfWeek, defaultTimeLocale, parseTimeM)
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
evaluatePredicateSimple doc = evaluatePredicateWithBindings Map.empty doc

evaluatePredicateWithBindings :: Map Text Text -> Aeson.Value -> Syntax.Predicate -> Bool
evaluatePredicateWithBindings bindings doc = \case
  -- Boolean literals
  Syntax.PTrue -> True
  Syntax.PFalse -> False
  -- Equality comparisons
  Syntax.Equals fieldRef val ->
    compareField bindings fieldRef val (==) doc
  Syntax.NotEquals fieldRef val ->
    compareField bindings fieldRef val (/=) doc
  -- Numeric comparisons
  Syntax.GreaterThan fieldRef val ->
    compareNumericField bindings fieldRef val (>) doc
  Syntax.LessThan fieldRef val ->
    compareNumericField bindings fieldRef val (<) doc
  Syntax.GreaterThanOrEqual fieldRef val ->
    compareNumericField bindings fieldRef val (>=) doc
  Syntax.LessThanOrEqual fieldRef val ->
    compareNumericField bindings fieldRef val (<=) doc
  -- Null checks
  Syntax.IsNull fieldRef ->
    isNothing $ lookupJsonFieldWithBindings bindings fieldRef doc
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupJsonFieldWithBindings bindings fieldRef doc
  -- Boolean logic (recursive)
  Syntax.And p1 p2 ->
    evaluatePredicateWithBindings bindings doc p1 && evaluatePredicateWithBindings bindings doc p2
  Syntax.Or p1 p2 ->
    evaluatePredicateWithBindings bindings doc p1 || evaluatePredicateWithBindings bindings doc p2
  Syntax.Not p ->
    not $ evaluatePredicateWithBindings bindings doc p
  -- Quantifiers over arrays
  Syntax.Exists path innerPred ->
    any (\item -> evaluatePredicateWithBindings bindings item innerPred) (findArrayItems path doc)
  Syntax.ForAll path innerPred ->
    all (\item -> evaluatePredicateWithBindings bindings item innerPred) (findArrayItems path doc)
  Syntax.Count path op n ->
    compareInt (length $ findArrayItems path doc) op n
  Syntax.HelperCall helperName args ->
    evaluateHelperCall bindings doc helperName args
  -- String operations
  Syntax.Contains fieldRef val ->
    case (lookupJsonFieldWithBindings bindings fieldRef doc, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    False -- TODO: Implement regex matching

-- | Evaluate a complete rule against a JSON document.
--
-- Returns a 'RuleResult' indicating whether the rule matched and what
-- action should be taken.
evaluateRuleSimple :: Aeson.Value -> Syntax.Rule -> RuleResult
evaluateRuleSimple doc rule =
  case buildBindingContext doc (Syntax.ruleBindings rule) of
    Left err ->
      RuleResult
        { resultRuleName = Syntax.ruleName rule,
          resultMatched = False,
          resultAction = Nothing,
          resultDetails = "Rule binding error: " <> err
        }
    Right bindings ->
      let matched = evaluatePredicateWithBindings bindings doc (Syntax.ruleCondition rule)
          action =
            if matched
              then Just (convertAction $ Syntax.ruleAction rule)
              else Nothing
          details =
            if matched
              then "Rule matched: " <> Syntax.ruleDescription rule
              else "Rule did not match"
       in RuleResult
            { resultRuleName = Syntax.ruleName rule,
              resultMatched = matched,
              resultAction = action,
              resultDetails = details
            }

buildBindingContext :: Aeson.Value -> [Syntax.Binding] -> Either Text (Map Text Text)
buildBindingContext doc = foldM step Map.empty
  where
    step ctx binding =
      case lookupJsonFieldWithBindings ctx (Syntax.bindingField binding) doc of
        Just value -> Right $ Map.insert (Syntax.bindingName binding) value ctx
        Nothing -> Left $ "Could not resolve LET binding '" <> Syntax.bindingName binding <> "'"

evaluateHelperCall :: Map Text Text -> Aeson.Value -> Text -> [Syntax.Value] -> Bool
evaluateHelperCall bindings doc helperName args =
  case T.toLower helperName of
    "is_weekend" ->
      case args of
        [arg] -> maybe False isWeekend (resolveArgText bindings doc arg)
        _ -> False
    "is_high_amount" ->
      case args of
        [actualArg, thresholdArg] ->
          case (resolveArgNumber bindings doc actualArg, resolveArgNumber bindings doc thresholdArg) of
            (Just actual, Just threshold) -> actual > threshold
            _ -> False
        _ -> False
    "starts_with" ->
      case args of
        [textArg, prefixArg] ->
          case (resolveArgText bindings doc textArg, resolveArgText bindings doc prefixArg) of
            (Just textVal, Just prefixVal) -> T.isPrefixOf prefixVal textVal
            _ -> False
        _ -> False
    "in_list" ->
      case args of
        [textArg, listArg] ->
          case (resolveArgText bindings doc textArg, resolveArgTextList bindings doc listArg) of
            (Just textVal, Just values) -> textVal `elem` values
            _ -> False
        _ -> False
    _ -> False

resolveArgText :: Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe Text
resolveArgText bindings doc arg =
  case arg of
    Syntax.StringValue t -> Just t
    Syntax.NumberValue d -> Just (T.pack (show d))
    Syntax.DateValue t -> Just t
    Syntax.FieldRefValue fieldRef -> lookupJsonFieldWithBindings bindings fieldRef doc
    Syntax.ListValue _ -> Nothing

resolveArgNumber :: Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe Double
resolveArgNumber bindings doc arg =
  case arg of
    Syntax.NumberValue d -> Just d
    Syntax.StringValue t -> textToDouble t
    Syntax.DateValue _ -> Nothing
    Syntax.FieldRefValue fieldRef -> lookupJsonFieldWithBindings bindings fieldRef doc >>= textToDouble
    Syntax.ListValue _ -> Nothing

resolveArgTextList :: Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe [Text]
resolveArgTextList bindings doc arg =
  case arg of
    Syntax.ListValue values -> mapM (resolveArgText bindings doc) values
    _ -> Nothing

isWeekend :: Text -> Bool
isWeekend dateText =
  case parseDate dateText of
    Just day ->
      let dow = dayOfWeek day
       in dow == Saturday || dow == Sunday
    Nothing -> False

parseDate :: Text -> Maybe Day
parseDate dateText =
  parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y%m%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" (T.unpack dateText)

-- ----------------------------------------------------------------------------
-- Field Comparison Helpers
-- ----------------------------------------------------------------------------

-- | Compare a field's string value against an expected value or another field.
compareField ::
  Map Text Text ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Text -> Text -> Bool) ->
  Aeson.Value ->
  Bool
compareField bindings fieldRef val cmp doc =
  case (lookupJsonFieldWithBindings bindings fieldRef doc, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) -> cmp fieldVal expectedVal
    (Just fieldVal, Syntax.FieldRefValue otherFieldRef) ->
      case lookupJsonFieldWithBindings bindings otherFieldRef doc of
        Just otherVal -> cmp fieldVal otherVal
        Nothing -> False
    _ -> False

-- | Compare a field's numeric value against an expected value or another field.
compareNumericField ::
  Map Text Text ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Double -> Double -> Bool) ->
  Aeson.Value ->
  Bool
compareNumericField bindings fieldRef val cmp doc =
  case (lookupJsonFieldWithBindings bindings fieldRef doc, val) of
    (Just fieldVal, Syntax.NumberValue expectedVal) ->
      case textToDouble fieldVal of
        Just actualVal -> cmp actualVal expectedVal
        Nothing -> False
    (Just fieldVal, Syntax.FieldRefValue otherFieldRef) ->
      case (textToDouble fieldVal, lookupJsonFieldWithBindings bindings otherFieldRef doc >>= textToDouble) of
        (Just actualVal, Just otherVal) -> cmp actualVal otherVal
        _ -> False
    _ -> False

-- | Compare two integers using a comparison operator.
compareInt :: Int -> Syntax.CompOp -> Int -> Bool
compareInt actual op expected = case op of
  Syntax.EQ -> actual == expected
  Syntax.NE -> actual /= expected
  Syntax.GT -> actual > expected
  Syntax.LT -> actual < expected
  Syntax.GTE -> actual >= expected
  Syntax.LTE -> actual <= expected

-- | Parse a Text value as a Double.
textToDouble :: Text -> Maybe Double
textToDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _ -> Nothing

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
    Nothing -- Not used for JSON

lookupJsonFieldWithBindings :: Map Text Text -> Syntax.FieldRef -> Aeson.Value -> Maybe Text
lookupJsonFieldWithBindings bindings fieldRef doc =
  case fieldRef of
    Syntax.Field name | not (T.isInfixOf "." name) ->
      case Map.lookup name bindings of
        Just value -> Just value
        Nothing -> lookupJsonField fieldRef doc
    _ -> lookupJsonField fieldRef doc

-- | Navigate a dot-separated path through JSON and extract a text value.
--
-- Handles both objects (by key) and arrays (by numeric index).
lookupPath :: [Text] -> Aeson.Value -> Maybe Text
lookupPath [] val = valueToText val
lookupPath (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPath rest
  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")]
        | idx >= 0 && idx < V.length arr ->
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
  Aeson.String t -> Just t
  Aeson.Number n -> Just $ T.pack $ show (toRealFloat n :: Double)
  Aeson.Bool True -> Just "true"
  Aeson.Bool False -> Just "false"
  Aeson.Null -> Nothing
  _ -> Nothing -- Arrays and objects can't be compared as text

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
    Just (Aeson.Array arr) -> V.toList arr
    Just obj@(Aeson.Object _) -> [obj] -- Single object as list of one
    _ -> []

-- | Navigate a path but return the raw JSON value (not converted to text).
lookupPathRaw :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPathRaw [] val = Just val
lookupPathRaw (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPathRaw rest
  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")]
        | idx >= 0 && idx < V.length arr ->
            lookupPathRaw rest (arr V.! idx)
      _ -> Nothing
  _ -> Nothing

-- ----------------------------------------------------------------------------
-- Action Conversion
-- ----------------------------------------------------------------------------

-- | Convert a Syntax.Action to Action' for inclusion in results.
convertAction :: Syntax.Action -> Action'
convertAction = \case
  Syntax.FlagFraud reason -> FlagFraud' reason
  Syntax.AssignRiskScore score -> AssignRiskScore' score
  Syntax.RequireReview note -> RequireReview' note
  Syntax.RejectClaim reason -> RejectClaim' reason
  Syntax.CompositeAction actions -> CompositeAction' (map convertAction actions)
