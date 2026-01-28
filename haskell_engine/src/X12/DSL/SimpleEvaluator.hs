{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.SimpleEvaluator
  ( evaluatePredicateSimple,
    evaluateRuleSimple,
    lookupJsonField,
  )
where

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

-- | Evaluate a predicate against any JSON value
evaluatePredicateSimple :: Aeson.Value -> Syntax.Predicate -> Bool
evaluatePredicateSimple doc pred = case pred of
  Syntax.PTrue -> True
  Syntax.PFalse -> False
  Syntax.Equals fieldRef val ->
    compareField fieldRef val (==) doc
  Syntax.NotEquals fieldRef val ->
    compareField fieldRef val (/=) doc
  Syntax.GreaterThan fieldRef val ->
    compareNumericField fieldRef val (>) doc
  Syntax.LessThan fieldRef val ->
    compareNumericField fieldRef val (<) doc
  Syntax.GreaterThanOrEqual fieldRef val ->
    compareNumericField fieldRef val (>=) doc
  Syntax.LessThanOrEqual fieldRef val ->
    compareNumericField fieldRef val (<=) doc
  Syntax.IsNull fieldRef ->
    isNothing $ lookupJsonField fieldRef doc
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupJsonField fieldRef doc
  Syntax.And p1 p2 ->
    evaluatePredicateSimple doc p1 && evaluatePredicateSimple doc p2
  Syntax.Or p1 p2 ->
    evaluatePredicateSimple doc p1 || evaluatePredicateSimple doc p2
  Syntax.Not p ->
    not $ evaluatePredicateSimple doc p
  Syntax.Exists path innerPred ->
    any (\item -> evaluatePredicateSimple item innerPred) (findArrayItems path doc)
  Syntax.ForAll path innerPred ->
    all (\item -> evaluatePredicateSimple item innerPred) (findArrayItems path doc)
  Syntax.Count path op n ->
    let count = length (findArrayItems path doc)
     in compareInt count op n
  Syntax.Contains fieldRef val ->
    case (lookupJsonField fieldRef doc, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    -- TODO: Implement regex matching
    False

-- | Evaluate a complete rule against simple JSON
evaluateRuleSimple :: Aeson.Value -> Syntax.Rule -> RuleResult
evaluateRuleSimple doc rule =
  let matched = evaluatePredicateSimple doc (Syntax.ruleCondition rule)
      action' = if matched then Just (convertAction $ Syntax.ruleAction rule) else Nothing
      details =
        if matched
          then "Rule matched: " <> Syntax.ruleDescription rule
          else "Rule did not match"
   in RuleResult (Syntax.ruleName rule) matched action' details

-- Helper functions

compareField :: Syntax.FieldRef -> Syntax.Value -> (Text -> Text -> Bool) -> Aeson.Value -> Bool
compareField fieldRef val cmp doc =
  case (lookupJsonField fieldRef doc, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) ->
      cmp fieldVal expectedVal
    _ -> False

compareNumericField :: Syntax.FieldRef -> Syntax.Value -> (Double -> Double -> Bool) -> Aeson.Value -> Bool
compareNumericField fieldRef val cmp doc =
  case (lookupJsonField fieldRef doc, val) of
    (Just fieldVal, Syntax.NumberValue expectedVal) ->
      case textToDouble fieldVal of
        Just actualVal -> cmp actualVal expectedVal
        Nothing -> False
    _ -> False

compareInt :: Int -> Syntax.CompOp -> Int -> Bool
compareInt actual op expected = case op of
  Syntax.EQ -> actual == expected
  Syntax.NE -> actual /= expected
  Syntax.GT -> actual > expected
  Syntax.LT -> actual < expected
  Syntax.GTE -> actual >= expected
  Syntax.LTE -> actual <= expected

textToDouble :: Text -> Maybe Double
textToDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _ -> Nothing

-- | Lookup a field in a JSON value using dot notation
-- Supports: "field", "parent.child", "array.0.field"
lookupJsonField :: Syntax.FieldRef -> Aeson.Value -> Maybe Text
lookupJsonField fieldRef doc = case fieldRef of
  -- Simple field name: look it up directly
  Syntax.Field name -> lookupPath (T.splitOn "." name) doc
  -- SegmentField: treat as "segment.field" path
  Syntax.SegmentField seg field -> lookupPath [seg, field] doc
  -- LoopField: treat as "loop.segment.field" path
  Syntax.LoopField loop seg field -> lookupPath [loop, seg, field] doc
  -- ElementPosition: not used for simple JSON
  Syntax.ElementPosition _ _ _ -> Nothing

-- | Navigate a JSON path and extract a text value
lookupPath :: [Text] -> Aeson.Value -> Maybe Text
lookupPath [] val = valueToText val
lookupPath (key : rest) val = case val of
  Aeson.Object obj ->
    case KM.lookup (Key.fromText key) obj of
      Just v -> lookupPath rest v
      Nothing -> Nothing
  Aeson.Array arr ->
    -- Try to parse key as array index
    case reads (T.unpack key) of
      [(idx, "")] | idx >= 0 && idx < V.length arr ->
        lookupPath rest (arr V.! idx)
      _ -> Nothing
  _ -> Nothing

-- | Convert JSON value to Text for comparison
valueToText :: Aeson.Value -> Maybe Text
valueToText val = case val of
  Aeson.String t -> Just t
  Aeson.Number n -> Just $ T.pack $ show (toRealFloat n :: Double)
  Aeson.Bool True -> Just "true"
  Aeson.Bool False -> Just "false"
  Aeson.Null -> Nothing
  _ -> Nothing

-- | Find array items for EXISTS/FORALL predicates
findArrayItems :: Syntax.SegmentPath -> Aeson.Value -> [Aeson.Value]
findArrayItems (Syntax.SegmentPath pathStr _) doc =
  case lookupPathRaw (T.splitOn "." pathStr) doc of
    Just (Aeson.Array arr) -> V.toList arr
    Just obj@(Aeson.Object _) -> [obj]  -- Single object treated as list of one
    _ -> []

-- | Navigate path but return raw JSON value (not converted to text)
lookupPathRaw :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPathRaw [] val = Just val
lookupPathRaw (key : rest) val = case val of
  Aeson.Object obj ->
    case KM.lookup (Key.fromText key) obj of
      Just v -> lookupPathRaw rest v
      Nothing -> Nothing
  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")] | idx >= 0 && idx < V.length arr ->
        lookupPathRaw rest (arr V.! idx)
      _ -> Nothing
  _ -> Nothing

convertAction :: Syntax.Action -> Action'
convertAction (Syntax.FlagFraud reason) = FlagFraud' reason
convertAction (Syntax.AssignRiskScore score) = AssignRiskScore' score
convertAction (Syntax.RequireReview note) = RequireReview' note
convertAction (Syntax.RejectClaim reason) = RejectClaim' reason
convertAction (Syntax.CompositeAction actions) = CompositeAction' (map convertAction actions)
