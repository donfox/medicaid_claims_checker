{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
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
-- * __Condition overlap__: constraints on a shared field that can all hold
--   at once, with no claim-level field on which the rules clash
--
-- Actions are compared by outcome: two @FLAG_FRAUD@ actions are the same
-- action whatever their messages say, while risk scores must be equal.
--
-- Conditions are compared after 'canonicalCondition': LET names are
-- replaced by their field paths and loop variables get canonical names, so
-- rules that differ only in those names compare as equal.
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
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
  | pc == pe && ruleAction candidate == ruleAction existing =
      [match ExactDuplicate ("Condition and action are identical to " <> quote existing)]
  | pc == pe && sameAction =
      [match ExactDuplicate ("Same condition and action as " <> quote existing <> "; only the message differs")]
  | pc == pe =
      [match Shadowed ("Same condition as " <> quote existing <> " but a different action — conflict")]
  | candidateNarrower || predicateImplies pe pc =
      [match (if sameAction then Subsumption else Shadowed) subsumption]
  | hasConditionOverlap pc pe =
      [match ConditionOverlap ("Shares overlapping field constraints with " <> quote existing)]
  | otherwise = []
  where
    pc = canonicalCondition candidate
    pe = canonicalCondition existing
    sameAction = outcome (ruleAction candidate) == outcome (ruleAction existing)
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

-- | An action with its message text blanked, so actions compare by what
-- they do to the claim.
outcome :: Action -> Action
outcome (FlagFraud _) = FlagFraud ""
outcome (RequireReview _) = RequireReview ""
outcome (RejectClaim _) = RejectClaim ""
outcome (ApproveClaim _) = ApproveClaim ""
outcome (AssignRiskScore n) = AssignRiskScore n
outcome (CompositeAction as) = CompositeAction (nub (sort (map outcome as)))

-- ----------------------------------------------------------------------------
-- Condition overlap
-- ----------------------------------------------------------------------------

-- | Two conditions overlap if, on some field both constrain, their
-- constraints can all hold at once, and no claim-level field rules out a
-- claim matching both. Each condition's constraints on a field are combined
-- before comparing, so @BETWEEN 1 AND 5@ and @BETWEEN 7 AND 14@ do not
-- overlap even though @>= 1@ and @>= 7@ would on their own.
--
-- Claim-level constraints (outside any quantifier) must all hold for a rule
-- to fire, so a clash there proves no claim matches both. A clash inside
-- @EXISTS@ proves nothing (two different items could match), so those
-- fields only count towards an overlap.
hasConditionOverlap :: Predicate -> Predicate -> Bool
hasConditionOverlap a b =
  let consA = filter usable (extractConstraints a)
      consB = filter usable (extractConstraints b)
      shared = [k | k <- nub (map key consA), any ((== k) . key) consB]
      onKey k = filter ((== k) . key)
      compatible k = satisfiable (onKey k consA ++ onKey k consB)
   in any compatible shared
        && all compatible [k | k@(Nothing, _) <- shared]
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

-- | Constraints we can reason about: numeric comparisons and equality with
-- a literal. Anything else (e.g. equality with another field) is ignored.
-- Conservative: an ignored constraint never produces an overlap and never
-- rules one out.
usable :: FieldConstraint -> Bool
usable c = case (fcOp c, fcValue c) of
  (_, NumberValue _)  -> True
  (EQ, StringValue _) -> True
  _                   -> False

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
intervalNonEmpty :: [(CompOp, Scientific)] -> Bool
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

-- | One end of an interval: a number, or unbounded. The derived order puts
-- 'NegInf' below every number and 'PosInf' above.
data Bound = NegInf | At Scientific | PosInf
  deriving (Show, Eq, Ord)

-- | The lower end of a constraint's interval and whether it is included.
lowerBound :: CompOp -> Scientific -> (Bound, Bool)
lowerBound EQ n = (At n, True)
lowerBound GT n = (At n, False)
lowerBound GTE n = (At n, True)
lowerBound _ _ = (NegInf, False)

-- | The upper end of a constraint's interval and whether it is included.
upperBound :: CompOp -> Scientific -> (Bound, Bool)
upperBound EQ n = (At n, True)
upperBound LT n = (At n, False)
upperBound LTE n = (At n, True)
upperBound _ _ = (PosInf, False)

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

-- | A rule's condition in canonical form, for comparing rules:
-- 'canonicalNames', then 'normalizePredicate'.
canonicalCondition :: Rule -> Predicate
canonicalCondition r = normalizePredicate (canonicalNames (ruleBindings r) (ruleCondition r))

-- | Rewrite every path in a condition so that names chosen by the rule's
-- author do not matter:
--
-- * A loop variable (@EXISTS line IN …@) becomes @_v0@, @_v1@, … by
--   nesting depth, wherever it starts a path: in fields, on the right of a
--   comparison, in helper arguments, in an inner collection and in COUNT.
-- * A LET name becomes its field path (a later LET may name an earlier
--   one), as the evaluator reads it. Inside an unnamed quantifier a LET
--   still means the whole claim, while a plain path means the item, so the
--   LET's path is marked with @$claim@ there to keep the two apart.
--
-- A loop variable shadows a LET of the same name, as in the evaluator.
canonicalNames :: [Binding] -> Predicate -> Predicate
canonicalNames bindings = go (Scope Map.empty 0 False)
  where
    lets = foldl bind Map.empty bindings
    bind acc (Binding name ref) = Map.insert name (expandLet acc ref) acc
    expandLet acc ref@(Path [single]) = Map.findWithDefault ref single acc
    expandLet _ ref = ref

    go sc p = case p of
      Compare op f v -> Compare op (path sc f) (value sc v)
      Between f lo hi -> Between (path sc f) (value sc lo) (value sc hi)
      Contains f v -> Contains (path sc f) v
      Matches f t -> Matches (path sc f) t
      IsNull f -> IsNull (path sc f)
      IsNotNull f -> IsNotNull (path sc f)
      HelperCall n args -> HelperCall n (map (value sc) args)
      Count cp op n -> Count (path sc cp) op n
      And a b -> And (go sc a) (go sc b)
      Or a b -> Or (go sc a) (go sc b)
      Not a -> Not (go sc a)
      Exists mv cp body -> quantifier Exists sc mv cp body
      ForAll mv cp body -> quantifier ForAll sc mv cp body
      other -> other

    -- The collection is read in the outer scope; the body in the new one.
    quantifier mk sc mv cp body =
      let inner = case mv of
            Nothing -> sc {scDepth = scDepth sc + 1, scUnnamed = True}
            Just v -> sc {scVars = Map.insert v (canonical sc) (scVars sc), scDepth = scDepth sc + 1}
       in mk (canonical sc <$ mv) (path sc cp) (go inner body)

    canonical sc = "_v" <> T.pack (show (scDepth sc))

    path sc (Path (first : rest))
      | Just c <- Map.lookup first (scVars sc) = Path (c : rest)
    path sc (Path [single])
      | Just (Path letParts) <- Map.lookup single lets =
          Path (if scUnnamed sc then "$claim" : letParts else letParts)
    path _ other = other

    value sc (FieldValue f) = FieldValue (path sc f)
    value sc (ListValue vs) = ListValue (map (value sc) vs)
    value _ v = v

-- | Where 'canonicalNames' is in a condition: loop variables in scope (with
-- their canonical names), quantifier depth, and whether it is inside an
-- unnamed quantifier.
data Scope = Scope
  { scVars :: Map Text Text,
    scDepth :: Int,
    scUnnamed :: Bool
  }

-- | Normalize a predicate for structural comparison (names are handled by
-- 'canonicalNames').
--
-- * Flatten nested 'And' / 'Or' into sorted lists
-- * Eliminate 'PTrue' from 'And', 'PFalse' from 'Or'
-- * Remove double negation: @NOT (NOT p)@ → @p@
-- * Write @BETWEEN@ as @>=@ and @<=@
normalizePredicate :: Predicate -> Predicate
normalizePredicate p = case p of
  And a b ->
    let conjuncts = sort $ flattenAnd (normalizePredicate a) ++ flattenAnd (normalizePredicate b)
        filtered = filter (/= PTrue) conjuncts
     in case filtered of
          [] -> PTrue
          [x] -> x
          (x : xs) -> foldl And x xs
  Or a b ->
    let disjuncts = sort $ flattenOr (normalizePredicate a) ++ flattenOr (normalizePredicate b)
        filtered = filter (/= PFalse) disjuncts
     in case filtered of
          [] -> PFalse
          [x] -> x
          (x : xs) -> foldl Or x xs
  Not (Not inner) -> normalizePredicate inner
  Not inner -> Not (normalizePredicate inner)
  Between f v1 v2 -> normalizePredicate (And (Compare GTE f v1) (Compare LTE f v2))
  Exists mv sp inner -> Exists mv sp (normalizePredicate inner)
  ForAll mv sp inner -> ForAll mv sp (normalizePredicate inner)
  other -> other

-- | Flatten nested 'And' nodes into a list of conjuncts.
flattenAnd :: Predicate -> [Predicate]
flattenAnd (And a b) = flattenAnd a ++ flattenAnd b
flattenAnd p = [p]

-- | Flatten nested 'Or' nodes into a list of disjuncts.
flattenOr :: Predicate -> [Predicate]
flattenOr (Or a b) = flattenOr a ++ flattenOr b
flattenOr p = [p]
