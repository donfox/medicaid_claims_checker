{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : X12.DSL.Evaluator
Description : Evaluate DSL predicates against X12Document structures
Stability   : experimental

This module evaluates fraud detection rules against parsed X12 documents
(as opposed to "X12.DSL.SimpleEvaluator" which works with generic JSON).

Use this evaluator when you have a fully parsed X12 document with its
hierarchical loop/segment structure intact. For flat JSON representations
of claims, use "X12.DSL.SimpleEvaluator" instead.

== Evaluation Process

1. Parse rules using "X12.DSL.Parser"
2. Parse X12 file into 'X12Document' structure
3. Call 'evaluateRule' for each rule against the document
4. Collect 'RuleResult' values

== Limitations

This evaluator is partially implemented:

* Simple field lookup ('Field') is not yet implemented
* Element position lookup ('ElementPosition') is not yet implemented
* Regex matching ('Matches') is not yet implemented
* Loop-scoped predicate evaluation is simplified

For production use with JSON claims, prefer "X12.DSL.SimpleEvaluator".
-}
module X12.DSL.Evaluator
  ( -- * Evaluation Functions
    evaluatePredicate
  , evaluateRule
  ) where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import X12.DSL.Syntax qualified as Syntax
import X12.DSL.X12Types

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

-- | Evaluate a predicate against an X12 document.
--
-- Returns 'True' if the predicate matches the document, 'False' otherwise.
--
-- ==== Example
--
-- @
-- let predicate = Syntax.GreaterThan (Syntax.SegmentField "CLM" "01") (Syntax.NumberValue 1000)
-- evaluatePredicate document predicate
-- @
evaluatePredicate :: X12Document -> Syntax.Predicate -> Bool
evaluatePredicate doc p = case p of
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
    isNothing $ lookupField fieldRef doc
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupField fieldRef doc

  -- Boolean logic
  Syntax.And p1 p2 ->
    evaluatePredicate doc p1 && evaluatePredicate doc p2
  Syntax.Or p1 p2 ->
    evaluatePredicate doc p1 || evaluatePredicate doc p2
  Syntax.Not inner ->
    not $ evaluatePredicate doc inner

  -- Quantifiers over loops
  Syntax.Exists path innerPred ->
    any (`evaluatePredicateInLoop` innerPred) (findLoops path doc)
  Syntax.ForAll path innerPred ->
    all (`evaluatePredicateInLoop` innerPred) (findLoops path doc)
  Syntax.Count path op n ->
    compareInt (length $ findLoops path doc) op n

  -- String operations
  Syntax.Contains fieldRef val ->
    case (lookupField fieldRef doc, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    False  -- TODO: Implement regex matching

-- | Evaluate a complete rule against a document.
--
-- Returns a 'RuleResult' indicating whether the rule matched and what
-- action should be taken.
evaluateRule :: X12Document -> Syntax.Rule -> RuleResult
evaluateRule doc rule =
  let matched = evaluatePredicate doc (Syntax.ruleCondition rule)
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
  -> X12Document
  -> Bool
compareField fieldRef val cmp doc =
  case (lookupField fieldRef doc, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) -> cmp fieldVal expectedVal
    _ -> False

-- | Compare a field's numeric value against an expected value.
compareNumericField
  :: Syntax.FieldRef
  -> Syntax.Value
  -> (Double -> Double -> Bool)
  -> X12Document
  -> Bool
compareNumericField fieldRef val cmp doc =
  case (lookupField fieldRef doc, val) of
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
-- Field Lookup
-- ----------------------------------------------------------------------------

-- | Look up a field value in an X12 document.
--
-- Supports segment-qualified and loop-qualified field references.
-- Simple field names and element positions are not yet implemented.
lookupField :: Syntax.FieldRef -> X12Document -> Maybe Text
lookupField fieldRef doc = case fieldRef of
  Syntax.Field _name ->
    -- Simple field lookup would need a field name mapping
    Nothing

  Syntax.SegmentField segId fieldName ->
    -- Find first matching segment and extract the field
    let allSegs     = concatMap extractAllSegments (docInterchanges doc)
        matchingSegs = filter (\s -> segmentId s == segId) allSegs
    in case matchingSegs of
         (seg : _) -> lookupSegmentField fieldName seg
         []        -> Nothing

  Syntax.LoopField lid segId fieldName ->
    -- Find loops, then segments within those loops
    let loops       = concatMap (extractLoopsById lid) (docInterchanges doc)
        segs        = concatMap loopSegments loops
        matchingSegs = filter (\s -> segmentId s == segId) segs
    in case matchingSegs of
         (seg : _) -> lookupSegmentField fieldName seg
         []        -> Nothing

  Syntax.ElementPosition _seg _elem _subelem ->
    -- Direct element position lookup not yet implemented
    Nothing

-- | Look up a field within a segment by element position.
--
-- Field names like "01", "02" map to element positions.
-- This is a simplified implementation.
lookupSegmentField :: Text -> Segment -> Maybe Text
lookupSegmentField fieldName seg =
  case segmentElements seg of
    (e : _)     | fieldName == "01" -> Just (elementValue e)
    (_ : e : _) | fieldName == "02" -> Just (elementValue e)
    _                               -> Nothing

-- ----------------------------------------------------------------------------
-- Loop Navigation
-- ----------------------------------------------------------------------------

-- | Find all loops matching a segment path.
findLoops :: Syntax.SegmentPath -> X12Document -> [Loop]
findLoops (Syntax.SegmentPath lid _segmentIds) doc =
  concatMap (extractLoopsById lid) (docInterchanges doc)

-- | Extract loops with a given ID from an interchange.
extractLoopsById :: Text -> Interchange -> [Loop]
extractLoopsById lid interchange =
  concatMap (extractLoopsFromGroup lid) (intGroups interchange)

-- | Extract loops with a given ID from a functional group.
extractLoopsFromGroup :: Text -> FunctionalGroup -> [Loop]
extractLoopsFromGroup lid group =
  concatMap (extractLoopsFromTx lid) (fgTransactions group)

-- | Extract loops with a given ID from a transaction.
extractLoopsFromTx :: Text -> Transaction -> [Loop]
extractLoopsFromTx lid tx =
  fromMaybe [] $ Map.lookup lid (txLoops tx)

-- ----------------------------------------------------------------------------
-- Segment Extraction
-- ----------------------------------------------------------------------------

-- | Extract all segments from an interchange (flattening the hierarchy).
extractAllSegments :: Interchange -> [Segment]
extractAllSegments interchange =
  concatMap extractSegmentsFromGroup (intGroups interchange)

-- | Extract all segments from a functional group.
extractSegmentsFromGroup :: FunctionalGroup -> [Segment]
extractSegmentsFromGroup group =
  concatMap extractSegmentsFromTx (fgTransactions group)

-- | Extract all segments from a transaction.
extractSegmentsFromTx :: Transaction -> [Segment]
extractSegmentsFromTx tx =
  concatMap extractSegmentsFromLoop (concat $ Map.elems $ txLoops tx)

-- | Extract all segments from a loop (including nested loops).
extractSegmentsFromLoop :: Loop -> [Segment]
extractSegmentsFromLoop loop =
  loopSegments loop ++ concatMap extractSegmentsFromLoop (loopChildren loop)

-- ----------------------------------------------------------------------------
-- Loop-Scoped Evaluation
-- ----------------------------------------------------------------------------

-- | Evaluate a predicate in the context of a specific loop.
--
-- TODO: This is a placeholder. Full implementation would create a
-- scoped evaluation context where field lookups are relative to the loop.
evaluatePredicateInLoop :: Loop -> Syntax.Predicate -> Bool
evaluatePredicateInLoop _loop _predicate =
  True  -- Placeholder: always returns True

-- ----------------------------------------------------------------------------
-- Action Conversion
-- ----------------------------------------------------------------------------

-- | Convert a Syntax.Action to Action' for inclusion in results.
--
-- This conversion exists because Action' is defined in X12Types to
-- avoid circular module dependencies.
convertAction :: Syntax.Action -> Action'
convertAction = \case
  Syntax.FlagFraud reason       -> FlagFraud' reason
  Syntax.AssignRiskScore score  -> AssignRiskScore' score
  Syntax.RequireReview note     -> RequireReview' note
  Syntax.RejectClaim reason     -> RejectClaim' reason
  Syntax.CompositeAction actions -> CompositeAction' (map convertAction actions)
