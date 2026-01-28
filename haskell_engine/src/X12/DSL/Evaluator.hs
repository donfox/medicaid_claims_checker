{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.Evaluator
  ( evaluatePredicate,
    evaluateRule,
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import X12.DSL.Syntax qualified as Syntax
import X12.DSL.X12Types

-- | Evaluate a predicate against an X12 document
evaluatePredicate :: X12Document -> Syntax.Predicate -> Bool
evaluatePredicate doc pred = case pred of
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
    isNothing $ lookupField fieldRef doc
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupField fieldRef doc
  Syntax.And p1 p2 ->
    evaluatePredicate doc p1 && evaluatePredicate doc p2
  Syntax.Or p1 p2 ->
    evaluatePredicate doc p1 || evaluatePredicate doc p2
  Syntax.Not p ->
    not $ evaluatePredicate doc p
  Syntax.Exists path innerPred ->
    any (\loop -> evaluatePredicateInLoop loop innerPred) (findLoops path doc)
  Syntax.ForAll path innerPred ->
    all (\loop -> evaluatePredicateInLoop loop innerPred) (findLoops path doc)
  Syntax.Count path op n ->
    let count = length (findLoops path doc)
     in compareInt count op n
  Syntax.Contains fieldRef val ->
    case (lookupField fieldRef doc, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    -- TODO: Implement regex matching
    False

-- | Evaluate a complete rule
evaluateRule :: X12Document -> Syntax.Rule -> RuleResult
evaluateRule doc rule =
  let matched = evaluatePredicate doc (Syntax.ruleCondition rule)
      action' = if matched then Just (convertAction $ Syntax.ruleAction rule) else Nothing
      details =
        if matched
          then "Rule matched: " <> Syntax.ruleDescription rule
          else "Rule did not match"
   in RuleResult (Syntax.ruleName rule) matched action' details

-- Helper functions

compareField :: Syntax.FieldRef -> Syntax.Value -> (Text -> Text -> Bool) -> X12Document -> Bool
compareField fieldRef val cmp doc =
  case (lookupField fieldRef doc, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) ->
      cmp fieldVal expectedVal
    _ -> False

compareNumericField :: Syntax.FieldRef -> Syntax.Value -> (Double -> Double -> Bool) -> X12Document -> Bool
compareNumericField fieldRef val cmp doc =
  case (lookupField fieldRef doc, val) of
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

lookupField :: Syntax.FieldRef -> X12Document -> Maybe Text
lookupField (Syntax.Field _name) _doc =
  -- Simple field lookup - would need field name mapping
  Nothing
lookupField (Syntax.SegmentField segId fieldName) doc =
  -- Find segment and extract field
  let allSegments = concatMap extractAllSegments (docInterchanges doc)
      matchingSegs = filter (\s -> segmentId s == segId) allSegments
   in case matchingSegs of
        (seg : _) -> lookupSegmentField fieldName seg
        [] -> Nothing
lookupField (Syntax.LoopField loopId segId fieldName) doc =
  let loops = concatMap (extractLoopsById loopId) (docInterchanges doc)
      segments = concatMap loopSegments loops
      matchingSegs = filter (\s -> segmentId s == segId) segments
   in case matchingSegs of
        (seg : _) -> lookupSegmentField fieldName seg
        [] -> Nothing
lookupField (Syntax.ElementPosition _seg _elem _subelem) _doc =
  -- Direct element position lookup
  Nothing

lookupSegmentField :: Text -> Segment -> Maybe Text
lookupSegmentField fieldName seg =
  -- This is simplified - would need proper field mapping
  case segmentElements seg of
    (e : _) | fieldName == "01" -> Just (elementValue e)
    (_ : e : _) | fieldName == "02" -> Just (elementValue e)
    _ -> Nothing

findLoops :: Syntax.SegmentPath -> X12Document -> [Loop]
findLoops (Syntax.SegmentPath loopId _segmentIds) doc =
  concatMap (extractLoopsById loopId) (docInterchanges doc)

extractLoopsById :: Text -> Interchange -> [Loop]
extractLoopsById loopId interchange =
  concatMap (extractLoopsFromGroup loopId) (intGroups interchange)

extractLoopsFromGroup :: Text -> FunctionalGroup -> [Loop]
extractLoopsFromGroup loopId group =
  concatMap (extractLoopsFromTx loopId) (fgTransactions group)

extractLoopsFromTx :: Text -> Transaction -> [Loop]
extractLoopsFromTx loopId tx =
  fromMaybe [] $ Map.lookup loopId (txLoops tx)

extractAllSegments :: Interchange -> [Segment]
extractAllSegments interchange =
  concatMap extractSegmentsFromGroup (intGroups interchange)

extractSegmentsFromGroup :: FunctionalGroup -> [Segment]
extractSegmentsFromGroup group =
  concatMap extractSegmentsFromTx (fgTransactions group)

extractSegmentsFromTx :: Transaction -> [Segment]
extractSegmentsFromTx tx =
  concatMap extractSegmentsFromLoop (concat $ Map.elems $ txLoops tx)

extractSegmentsFromLoop :: Loop -> [Segment]
extractSegmentsFromLoop loop =
  loopSegments loop ++ concatMap extractSegmentsFromLoop (loopChildren loop)

evaluatePredicateInLoop :: Loop -> Syntax.Predicate -> Bool
evaluatePredicateInLoop _loop _pred =
  -- Would need to evaluate predicate in the context of a specific loop
  True

convertAction :: Syntax.Action -> Action'
convertAction (Syntax.FlagFraud reason) = FlagFraud' reason
convertAction (Syntax.AssignRiskScore score) = AssignRiskScore' score
convertAction (Syntax.RequireReview note) = RequireReview' note
convertAction (Syntax.RejectClaim reason) = RejectClaim' reason
convertAction (Syntax.CompositeAction actions) = CompositeAction' (map convertAction actions)
