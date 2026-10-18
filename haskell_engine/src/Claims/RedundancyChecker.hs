{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.RedundancyChecker
-- Description : Detect redundant rules at four levels
-- Stability   : experimental
--
-- Compares a candidate rule against existing rules to detect:
--
-- * __Exact duplicate__: same condition and action
-- * __Subsumption__: one condition implies the other, same action (redundant)
-- * __Shadowed__: one condition implies the other, different action (conflict)
-- * __Condition overlap__: constraints on a shared field that can all hold at once
--
-- Every check is conservative: it reports only what it can prove.
module Claims.RedundancyChecker
  ( RedundancyLevel (..),
    RedundancyMatch (..),
    checkRedundancy,
  )
where

import Data.Aeson (ToJSON)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Prelude hiding (EQ, GT, LT)
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

-- | Compare a candidate rule with each existing rule. Reports at most one
-- match per existing rule: the most specific level found.
checkRedundancy :: Rule -> [Rule] -> [RedundancyMatch]
checkRedundancy candidate = concatMap (compareRules candidate)

compareRules :: Rule -> Rule -> [RedundancyMatch]
compareRules candidate existing
  | pc == pe && sameAction =
      [match ExactDuplicate ("Condition and action are identical to " <> quote existing)]
  | pc == pe =
      [match Shadowed ("Same condition as " <> quote existing <> " but a different action — conflict")]
  | candidateNarrower || predicateImplies pe pc =
      [match (if sameAction then Subsumption else Shadowed) subsumption]
  | hasConditionOverlap candidate existing =
      [match ConditionOverlap ("Shares overlapping field constraints with " <> quote existing)]
  | otherwise = []
  where
    pc = normalizePredicate (ruleCondition candidate)
    pe = normalizePredicate (ruleCondition existing)
    sameAction = ruleAction candidate == ruleAction existing
    candidateNarrower = predicateImplies pc pe
    match level = RedundancyMatch level (ruleName existing)
    quote r = "'" <> ruleName r <> "'"
    subsumption =
      (if candidateNarrower
         then quote candidate <> " is more specific than " <> quote existing
                <> " — existing rule covers all cases this rule would match"
         else quote existing <> " is more specific than " <> quote candidate
                <> " — new rule would cover all cases " <> quote existing <> " matches")
        <> (if sameAction then "" else " (different actions — possible conflict)")

-- ----------------------------------------------------------------------------
-- Condition overlap
-- ----------------------------------------------------------------------------

-- | Two rules overlap if, on some field both constrain, their constraints
-- can all hold at once. Each rule's constraints on a field are combined
-- before comparing, so @BETWEEN 1 AND 5@ and @BETWEEN 7 AND 14@ do not
-- overlap even though @>= 1@ and @>= 7@ would on their own.
hasConditionOverlap :: Rule -> Rule -> Bool
hasConditionOverlap a b =
  let consA = filter usable (extractConstraints (ruleCondition a))
      consB = filter usable (extractConstraints (ruleCondition b))
      keys = nub (map key consA)
      onKey k = filter ((== k) . key)
   in any
        (\k -> not (null (onKey k consB)) && satisfiable (onKey k consA ++ onKey k consB))
        keys
  where
    key c = (fcScope c, fcField c)

-- | A leaf constraint extracted from a predicate tree, tagged with the
-- quantifier scope (if any) it was extracted under.
data FieldConstraint = FieldConstraint
  { fcScope :: Maybe Path,
    fcField :: Path,
    fcOp :: CompOp,
    fcValue :: Value
  }
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
      Compare NE _ _  -> []
      Compare op f v  -> [FieldConstraint scope f op v]
      Between f v1 v2 -> [FieldConstraint scope f GTE v1, FieldConstraint scope f LTE v2]
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

-- | Constraints we can reason about: numeric comparisons and equality.
-- Anything else (e.g. @>@ on a string) is ignored. Conservative: an
-- ignored constraint never produces an overlap.
usable :: FieldConstraint -> Bool
usable c = case (fcOp c, fcValue c) of
  (_, NumberValue _) -> True
  (EQ, _)            -> True
  _                  -> False

-- | Can every constraint in the list hold at once? All are on one field.
-- Numbers must leave a non-empty interval; other values must all be
-- equal; a number and a non-number cannot both be the field's value.
satisfiable :: [FieldConstraint] -> Bool
satisfiable cs =
  case ([(fcOp c, n) | c <- cs, NumberValue n <- [fcValue c]], [v | c <- cs, let v = fcValue c, not (isNumber v)]) of
    (nums, []) -> intervalNonEmpty nums
    ([], v : vs) -> all (== v) vs
    _ -> False
  where
    isNumber (NumberValue _) = True
    isNumber _ = False

-- | Is the intersection of these numeric constraints non-empty? Each is
-- an interval whose ends may be open or closed. @> 5@ and @< 5@ leave
-- nothing; @>= 5@ and @<= 5@ leave 5.
intervalNonEmpty :: [(CompOp, Double)] -> Bool
intervalNonEmpty cs =
  let (lo, loClosed) = foldr1 (tighter (>)) [lowerBound op n | (op, n) <- cs]
      (hi, hiClosed) = foldr1 (tighter (<)) [upperBound op n | (op, n) <- cs]
   in lo < hi || (lo == hi && loClosed && hiClosed)
  where
    -- Pick the tighter of two bounds; on a tie the result is closed only
    -- when both are.
    tighter better (a, ca) (b, cb)
      | a `better` b = (a, ca)
      | b `better` a = (b, cb)
      | otherwise = (a, ca && cb)

-- | The lower end of a constraint's interval and whether it is included.
lowerBound :: CompOp -> Double -> (Double, Bool)
lowerBound EQ n = (n, True)
lowerBound GT n = (n, False)
lowerBound GTE n = (n, True)
lowerBound _ _ = (-1 / 0, False)

-- | The upper end of a constraint's interval and whether it is included.
upperBound :: CompOp -> Double -> (Double, Bool)
upperBound EQ n = (n, True)
upperBound LT n = (n, False)
upperBound LTE n = (n, True)
upperBound _ _ = (1 / 0, False)

-- ----------------------------------------------------------------------------
-- Implication
-- ----------------------------------------------------------------------------

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
-- And on the right: p implies (a AND b) exactly when p implies both.
-- This must come before splitting an And on the left, or
-- (x > 1000 AND s = "NY") would never be found to imply (x > 500 AND s = "NY").
predicateImplies p (And a b) =
  predicateImplies p a && predicateImplies p b
-- And: if p = (a AND b), then p implies q if either conjunct implies q
predicateImplies (And a b) q =
  predicateImplies a q || predicateImplies b q
-- Or: p implies (a OR b) if p implies either disjunct
predicateImplies p (Or a b) =
  predicateImplies p a || predicateImplies p b
-- Numbers on the same field: p implies q when p's range of values lies
-- inside q's. So > 1000 implies > 500, and = 60000 implies >= 50000.
predicateImplies (Compare op1 f1 (NumberValue n1)) (Compare op2 f2 (NumberValue n2))
  | f1 == f2, op1 /= NE, op2 /= NE =
      inside (>) (lowerBound op1 n1) (lowerBound op2 n2)
        && inside (<) (upperBound op1 n1) (upperBound op2 n2)
  where
    -- One end of p's range is inside q's when it is strictly tighter, or the
    -- same value and not included in p unless it is included in q.
    inside tighter (a, aIncluded) (b, bIncluded) =
      a `tighter` b || (a == b && (bIncluded || not aIncluded))
predicateImplies (Compare EQ f1 v1) (Compare EQ f2 v2) =
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
        go depth (And (Compare GTE f v1) (Compare LTE f v2))
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

-- | Rename a bound variable where it starts a field path (@var.field@).
-- Stops at nested quantifiers that shadow the same name.
renameVar :: Text -> Text -> Predicate -> Predicate
renameVar old new = go
  where
    renameField (Path (first : rest@(_ : _))) | first == old = Path (new : rest)
    renameField other = other

    go pred' = case pred' of
      Compare op f v          -> Compare op (renameField f) v
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
