{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.RedundancyChecker
-- Description : Detect redundant rules at four levels
-- Stability   : experimental
--
-- Compares a candidate rule against existing rules to detect:
--
-- * __Level 1 — Exact Duplicate__: identical condition AND action
-- * __Level 2 — Subsumption__: condition implies + same action (truly redundant)
-- * __Level 3 — Shadowed__: condition implies + different action (conflict)
-- * __Level 4 — Condition Overlap__: same fields with overlapping ranges
module Claims.RedundancyChecker
  ( RedundancyLevel (..),
    RedundancyMatch (..),
    checkRedundancy,
    normalizePredicate,
    predicateImplies,
  )
where

import Data.Aeson (ToJSON)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Claims.Syntax

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

-- | How two rules are related, ordered from most to least specific.
data RedundancyLevel
  = ExactDuplicate
  | Subsumption        -- ^ condition implies + same action (truly redundant)
  | Shadowed           -- ^ condition implies + different action (conflict)
  | ConditionOverlap
  deriving (Show, Eq, Ord, Generic)

instance ToJSON RedundancyLevel

-- | A detected redundancy between the candidate and an existing rule.
data RedundancyMatch = RedundancyMatch
  { matchLevel :: RedundancyLevel,
    matchRuleName :: Text,
    matchExplanation :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RedundancyMatch

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

-- | Check a candidate rule against a list of existing rules.
-- Returns all detected redundancies, at most one per existing rule
-- (the most specific level found).
checkRedundancy :: Rule -> [Rule] -> [RedundancyMatch]
checkRedundancy candidate = concatMap (compareRules candidate)

-- ----------------------------------------------------------------------------
-- Per-pair comparison
-- ----------------------------------------------------------------------------

-- | Compare candidate against one existing rule.
-- Returns at most one match (the most specific level).
compareRules :: Rule -> Rule -> [RedundancyMatch]
compareRules candidate existing
  | isExactDuplicate candidate existing =
      [ RedundancyMatch
          ExactDuplicate
          (ruleName existing)
          ( "Condition and action are identical to '"
              <> ruleName existing
              <> "'"
          )
      ]
  | hasSubsumption candidate existing =
      let sameAction = ruleAction candidate == ruleAction existing
          level = if sameAction then Subsumption else Shadowed
       in [ RedundancyMatch
              level
              (ruleName existing)
              (subsumptionExplanation level candidate existing)
          ]
  | hasConditionOverlap candidate existing =
      [ RedundancyMatch
          ConditionOverlap
          (ruleName existing)
          ( "Shares overlapping field constraints with '"
              <> ruleName existing
              <> "'"
          )
      ]
  | otherwise = []

-- ----------------------------------------------------------------------------
-- Level 1: Exact Duplicate
-- ----------------------------------------------------------------------------

-- | Two rules are exact duplicates when their normalized conditions
-- and actions are structurally equal (ignoring name and description).
isExactDuplicate :: Rule -> Rule -> Bool
isExactDuplicate a b =
  normalizePredicate (ruleCondition a) == normalizePredicate (ruleCondition b)
    && ruleAction a == ruleAction b

-- ----------------------------------------------------------------------------
-- Level 2: Condition Overlap
-- ----------------------------------------------------------------------------

-- | Two rules overlap if they share constraints on the same field
-- with overlapping value ranges.
hasConditionOverlap :: Rule -> Rule -> Bool
hasConditionOverlap a b =
  let consA = extractConstraints (ruleCondition a)
      consB = extractConstraints (ruleCondition b)
   in any (\ca -> any (constraintsOverlap ca) consB) consA

-- | A leaf constraint extracted from a predicate tree, tagged with the
-- quantifier scope (if any) it was extracted under.
data FieldConstraint = FieldConstraint
  { fcScope :: Maybe SegmentPath,
    fcField :: FieldRef,
    fcOp :: ConstraintOp,
    fcValue :: Value
  }
  deriving (Show, Eq)

data ConstraintOp = CEq | CNe | CGt | CLt | CGte | CLte
  deriving (Show, Eq)

-- | Walk the predicate tree and collect leaf field constraints.
-- Top-level constraints have scope 'Nothing'; constraints inside
-- quantifiers are tagged with the quantifier's collection path.
extractConstraints :: Predicate -> [FieldConstraint]
extractConstraints = go Nothing
  where
    go scope p = case p of
      PTrue           -> []
      PFalse          -> []
      Equals f v      -> [FieldConstraint scope f CEq v]
      NotEquals _ _   -> []
      GreaterThan f v -> [FieldConstraint scope f CGt v]
      LessThan f v    -> [FieldConstraint scope f CLt v]
      GreaterThanOrEqual f v -> [FieldConstraint scope f CGte v]
      LessThanOrEqual f v    -> [FieldConstraint scope f CLte v]
      Between f v1 v2 -> [FieldConstraint scope f CGte v1, FieldConstraint scope f CLte v2]
      Contains _ _    -> []
      IsNull _        -> []
      IsNotNull _     -> []
      Matches _ _     -> []
      HasDiagnosis _  -> []
      HasProcedure _  -> []
      And a b         -> go scope a ++ go scope b
      Or _ _          -> []   -- disjuncts are not conjunctive; unsafe to extract
      Not _           -> []   -- negated predicates invert meaning; unsafe to extract
      Exists _ sp q   -> go (Just sp) q
      ForAll _ sp q   -> go (Just sp) q
      Count _ _ _     -> []
      HelperCall _ _  -> []

-- | Do two constraints on the same field have overlapping value ranges?
-- Constraints must share the same scope (quantifier path) to overlap.
constraintsOverlap :: FieldConstraint -> FieldConstraint -> Bool
constraintsOverlap a b
  | fcScope a /= fcScope b = False
  | fcField a /= fcField b = False
  | otherwise = valuesOverlap (fcOp a) (fcValue a) (fcOp b) (fcValue b)

-- | Check if two (operator, value) pairs on the same field overlap.
valuesOverlap :: ConstraintOp -> Value -> ConstraintOp -> Value -> Bool
-- String equality: overlap if same value
valuesOverlap CEq (StringValue s1) CEq (StringValue s2) = s1 == s2
-- Numeric comparisons
valuesOverlap op1 (NumberValue n1) op2 (NumberValue n2) =
  numericRangesOverlap op1 n1 op2 n2
-- Same equality on any value type
valuesOverlap CEq v1 CEq v2 = v1 == v2
-- Conservative: if we can't determine, don't flag overlap
valuesOverlap _ _ _ _ = False

-- | Do two numeric constraints on the same field have overlapping ranges?
-- We model each constraint as a half-line and check if the intersection
-- is non-empty.
numericRangesOverlap :: ConstraintOp -> Double -> ConstraintOp -> Double -> Bool
numericRangesOverlap op1 n1 op2 n2 =
  let (lo1, hi1) = opToRange op1 n1
      (lo2, hi2) = opToRange op2 n2
      lo = max lo1 lo2
      hi = min hi1 hi2
   in lo < hi || (lo == hi && lo /= inf && lo /= negInf)
  where
    inf = 1 / 0 :: Double
    negInf = -1 / 0 :: Double

-- | Convert a comparison operator + value into a (lo, hi) interval.
opToRange :: ConstraintOp -> Double -> (Double, Double)
opToRange CEq n = (n, n)
opToRange CNe _ = (negInf, inf)
  where
    inf = 1 / 0
    negInf = -1 / 0
opToRange CGt n = (n, inf) where inf = 1 / 0
opToRange CGte n = (n, inf) where inf = 1 / 0
opToRange CLt n = (negInf, n) where negInf = -1 / 0
opToRange CLte n = (negInf, n) where negInf = -1 / 0

-- ----------------------------------------------------------------------------
-- Level 3: Subsumption
-- ----------------------------------------------------------------------------

-- | One rule subsumes the other if its condition implies the other's.
hasSubsumption :: Rule -> Rule -> Bool
hasSubsumption a b =
  let pa = normalizePredicate (ruleCondition a)
      pb = normalizePredicate (ruleCondition b)
   in predicateImplies pa pb || predicateImplies pb pa

subsumptionExplanation :: RedundancyLevel -> Rule -> Rule -> Text
subsumptionExplanation level candidate existing =
  let pc = normalizePredicate (ruleCondition candidate)
      pe = normalizePredicate (ruleCondition existing)
      suffix = case level of
        Shadowed -> " (different actions — possible conflict)"
        _        -> ""
      direction
        | predicateImplies pc pe =
            "'"
              <> ruleName candidate
              <> "' is more specific than '"
              <> ruleName existing
              <> "' — existing rule covers all cases this rule would match"
        | otherwise =
            "'"
              <> ruleName existing
              <> "' is more specific than '"
              <> ruleName candidate
              <> "' — new rule would cover all cases '"
              <> ruleName existing
              <> "' matches"
   in direction <> suffix

-- | Conservative implication check.
--
-- @predicateImplies p q@ returns 'True' when we can determine that
-- whenever @p@ is true, @q@ must also be true (i.e., p ⊆ q).
predicateImplies :: Predicate -> Predicate -> Bool
-- Trivial cases
predicateImplies _ PTrue = True
predicateImplies PFalse _ = True
-- Reflexive (after normalization)
predicateImplies p q | p == q = True
-- And: if p = (a AND b), then p implies q if either conjunct implies q
predicateImplies (And a b) q =
  predicateImplies a q || predicateImplies b q
-- Or: p implies (a OR b) if p implies either disjunct
predicateImplies p (Or a b) =
  predicateImplies p a || predicateImplies p b
-- And on the right: p implies (a AND b) if p implies both
predicateImplies p (And a b) =
  predicateImplies p a && predicateImplies p b
-- Numeric tightening: stricter bound implies looser bound
predicateImplies (GreaterThan f1 (NumberValue n1)) (GreaterThan f2 (NumberValue n2)) =
  f1 == f2 && n1 >= n2
predicateImplies (GreaterThanOrEqual f1 (NumberValue n1)) (GreaterThan f2 (NumberValue n2)) =
  f1 == f2 && n1 > n2
predicateImplies (GreaterThan f1 (NumberValue n1)) (GreaterThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 >= n2
predicateImplies (GreaterThanOrEqual f1 (NumberValue n1)) (GreaterThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 >= n2
predicateImplies (LessThan f1 (NumberValue n1)) (LessThan f2 (NumberValue n2)) =
  f1 == f2 && n1 <= n2
predicateImplies (LessThanOrEqual f1 (NumberValue n1)) (LessThan f2 (NumberValue n2)) =
  f1 == f2 && n1 < n2
predicateImplies (LessThan f1 (NumberValue n1)) (LessThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 <= n2
predicateImplies (LessThanOrEqual f1 (NumberValue n1)) (LessThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 <= n2
-- Equality implies range: = 60000 implies > 50000
predicateImplies (Equals f1 (NumberValue n1)) (GreaterThan f2 (NumberValue n2)) =
  f1 == f2 && n1 > n2
predicateImplies (Equals f1 (NumberValue n1)) (GreaterThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 >= n2
predicateImplies (Equals f1 (NumberValue n1)) (LessThan f2 (NumberValue n2)) =
  f1 == f2 && n1 < n2
predicateImplies (Equals f1 (NumberValue n1)) (LessThanOrEqual f2 (NumberValue n2)) =
  f1 == f2 && n1 <= n2
-- String/value equality
predicateImplies (Equals f1 v1) (Equals f2 v2) =
  f1 == f2 && v1 == v2
-- IsNull / IsNotNull
predicateImplies (IsNull f1) (IsNull f2) = f1 == f2
predicateImplies (IsNotNull f1) (IsNotNull f2) = f1 == f2
-- Default: cannot determine implication
predicateImplies _ _ = False

-- ----------------------------------------------------------------------------
-- Predicate Normalization
-- ----------------------------------------------------------------------------

-- | Normalize a predicate for structural comparison.
--
-- * Flatten nested 'And' / 'Or' into sorted lists
-- * Eliminate 'PTrue' from 'And', 'PFalse' from 'Or'
-- * Remove double negation: @NOT (NOT p)@ → @p@
-- * Alpha-normalize bound variables in quantifiers
normalizePredicate :: Predicate -> Predicate
normalizePredicate = go 0
  where
    go depth p = case p of
      And a b ->
        let conjuncts = sort $ flattenAnd (go depth a) ++ flattenAnd (go depth b)
            filtered = filter (/= PTrue) conjuncts
         in case filtered of
              [] -> PTrue
              [x] -> x
              (x : xs) -> foldl And x xs
      Or a b ->
        let disjuncts = sort $ flattenOr (go depth a) ++ flattenOr (go depth b)
            filtered = filter (/= PFalse) disjuncts
         in case filtered of
              [] -> PFalse
              [x] -> x
              (x : xs) -> foldl Or x xs
      Not (Not inner) -> go depth inner
      Not inner -> Not (go depth inner)
      Between f v1 v2 ->
        go depth (And (GreaterThanOrEqual f v1) (LessThanOrEqual f v2))
      Exists mv sp inner ->
        let (mv', inner') = alphaNormalize depth mv inner
         in Exists mv' sp (go (depth + 1) inner')
      ForAll mv sp inner ->
        let (mv', inner') = alphaNormalize depth mv inner
         in ForAll mv' sp (go (depth + 1) inner')
      other -> other

-- | Rename a bound variable to a canonical name (@_v0@, @_v1@, …)
-- so that alpha-equivalent quantifiers compare as equal.
alphaNormalize :: Int -> Maybe Text -> Predicate -> (Maybe Text, Predicate)
alphaNormalize _ Nothing body = (Nothing, body)
alphaNormalize depth (Just oldName) body =
  let canonical = "_v" <> T.pack (show depth)
   in (Just canonical, renameVar oldName canonical body)

-- | Substitute all occurrences of a bound variable name in a predicate.
-- Bound variables appear as the first component of 'SegmentField'.
-- Stops at nested quantifiers that shadow the same variable name.
renameVar :: Text -> Text -> Predicate -> Predicate
renameVar old new = go
  where
    renameField (SegmentField seg f) | seg == old = SegmentField new f
    renameField (LoopField l s f)    | l == old   = LoopField new s f
    renameField other                              = other

    go pred' = case pred' of
      Equals f v              -> Equals (renameField f) v
      NotEquals f v           -> NotEquals (renameField f) v
      GreaterThan f v         -> GreaterThan (renameField f) v
      LessThan f v            -> LessThan (renameField f) v
      GreaterThanOrEqual f v  -> GreaterThanOrEqual (renameField f) v
      LessThanOrEqual f v     -> LessThanOrEqual (renameField f) v
      Contains f v            -> Contains (renameField f) v
      Matches f t             -> Matches (renameField f) t
      IsNull f                -> IsNull (renameField f)
      IsNotNull f             -> IsNotNull (renameField f)
      Between f v1 v2         -> Between (renameField f) v1 v2
      And a b                 -> And (go a) (go b)
      Or a b                  -> Or (go a) (go b)
      Not a                   -> Not (go a)
      -- Stop if a nested quantifier shadows this variable name
      Exists (Just v) sp body' | v == old -> Exists (Just v) sp body'
      ForAll (Just v) sp body' | v == old -> ForAll (Just v) sp body'
      Exists mv sp body'      -> Exists mv sp (go body')
      ForAll mv sp body'      -> ForAll mv sp (go body')
      other                   -> other

-- | Flatten nested 'And' nodes into a list of conjuncts.
flattenAnd :: Predicate -> [Predicate]
flattenAnd (And a b) = flattenAnd a ++ flattenAnd b
flattenAnd p = [p]

-- | Flatten nested 'Or' nodes into a list of disjuncts.
flattenOr :: Predicate -> [Predicate]
flattenOr (Or a b) = flattenOr a ++ flattenOr b
flattenOr p = [p]
