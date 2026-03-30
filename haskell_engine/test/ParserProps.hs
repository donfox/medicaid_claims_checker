{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : ParserProps
-- Description : QuickCheck property tests for Claims.Parser
--
-- This module demonstrates property-based testing applied to the DSL parser.
-- Instead of writing specific example inputs, we:
--
--   1. Define 'Arbitrary' instances that generate random AST values
--   2. Write a pretty-printer to convert AST nodes back to DSL text
--   3. Assert properties that must hold for ALL generated inputs
--
-- The core property is the __round-trip invariant__:
--
-- @
--   parseRule (prettyRule r) === Right r    -- for any rule r
-- @
--
-- If this holds, the parser and pretty-printer are perfect inverses of each
-- other — a much stronger guarantee than any finite set of hand-written tests.
--
-- == How QuickCheck works here
--
-- When 'checkProp' runs a property, QuickCheck:
--   1. Calls 'arbitrary' to generate 100 random inputs
--   2. Runs the property on each
--   3. If a failure is found, calls 'shrink' repeatedly to find the
--      __smallest__ input that still fails (counterexample minimization)
--   4. Reports the minimal failing case

module ParserProps (parserProperties) where

import qualified Data.Text as T
import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Claims.Parser (parseRule, parseRules)
import Claims.Syntax

-- ============================================================
-- Helper: run a QuickCheck property inside an Hspec 'it' block
--
-- We use 'quickCheckResult' (returns a structured Result) rather than
-- 'quickCheck' (just prints) so we can propagate failures into Hspec.
-- ============================================================

-- | Run a QuickCheck property as an Hspec expectation.
--
-- On failure, the counterexample output from QuickCheck becomes the
-- Hspec failure message.
checkProp :: Testable prop => prop -> IO ()
checkProp p = do
  result <- quickCheckResult p
  case result of
    Success {}            -> return ()
    Failure { output = msg } -> expectationFailure msg
    GaveUp  { output = msg } -> expectationFailure ("QuickCheck gave up:\n" <> msg)
    _                     -> expectationFailure "QuickCheck: unexpected result"


-- ============================================================
-- Safe identifier sets
--
-- These lists contain values that are:
--   * Not reserved DSL keywords (AND, OR, RULE, WHEN, etc.)
--   * Valid as identifiers, field names, and string literals
--   * Free of special characters that could confuse the parser
-- ============================================================

safeFieldNames :: [Text]
safeFieldNames =
  [ "amount", "status", "provider", "claim_id"
  , "code", "npi", "date_field", "total", "region"
  ]

safeSegments :: [Text]
safeSegments = ["CLM", "NM1", "SV1", "BHT", "DTP"]

safeLoops :: [Text]
safeLoops = ["2300", "2400", "2000", "2010"]

safeRuleNames :: [Text]
safeRuleNames =
  [ "rule_a", "rule_b", "check1", "check2"
  , "verify_amount", "flag_high", "review_status"
  ]

safeStrings :: [Text]
safeStrings =
  [ "pending", "approved", "denied", "active"
  , "outpatient", "male", "female", "tx", "ca"
  ]

-- | Pick a random element from a fixed list.
pickFrom :: [a] -> Gen a
pickFrom = elements

-- | Generate a whole-number Double (e.g. 42.0, 500.0).
--
-- We avoid fractional doubles because 'show' can produce scientific notation
-- for very small values (e.g. 1.0e-3) which the parser cannot read back.
-- Whole numbers always render as "42.0", which the parser handles fine.
genSafeDouble :: Gen Double
genSafeDouble = fromIntegral <$> choose (0 :: Int, 9999)


-- ============================================================
-- Arbitrary instances
--
-- Each 'Arbitrary' instance has two parts:
--   * 'arbitrary' — generator for random values
--   * 'shrink'    — how to reduce a failing value toward something simpler
--
-- Good shrinking means QuickCheck shows you the *smallest* failing input
-- rather than a large, hard-to-read counterexample.
-- ============================================================

instance Arbitrary FieldRef where
  arbitrary = oneof
    [ Field        <$> pickFrom safeFieldNames
    , SegmentField <$> pickFrom safeSegments <*> pickFrom safeFieldNames
    , LoopField    <$> pickFrom safeLoops    <*> pickFrom safeSegments <*> pickFrom safeFieldNames
    ]
  shrink (SegmentField _ f)   = [Field f]
  shrink (LoopField _ seg f)  = [SegmentField seg f, Field f]
  shrink _                    = []

instance Arbitrary Value where
  arbitrary = oneof
    [ StringValue <$> pickFrom safeStrings
    , NumberValue <$> genSafeDouble
    ]
  shrink (NumberValue n) = [NumberValue n' | n' <- shrink n, n' >= 0]
  shrink _               = []

-- | Generate a predicate with bounded depth using QuickCheck's 'sized'.
--
-- 'sized' passes a size parameter that shrinks with each recursive call,
-- preventing infinite generation. At size 0, only atomic (leaf) predicates
-- are produced.
instance Arbitrary Predicate where
  arbitrary = sized genPredicate
  shrink (And p1 p2) = [p1, p2]
                    ++ [And p1' p2  | p1' <- shrink p1]
                    ++ [And p1  p2' | p2' <- shrink p2]
  shrink (Or  p1 p2) = [p1, p2]
                    ++ [Or  p1' p2  | p1' <- shrink p1]
                    ++ [Or  p1  p2' | p2' <- shrink p2]
  shrink (Not p)     = [p] ++ [Not p' | p' <- shrink p]
  shrink _           = []

genPredicate :: Int -> Gen Predicate
genPredicate 0 = genAtomic
genPredicate n = frequency
  [ (5, genAtomic)
  , (2, And <$> genPredicate half <*> genPredicate half)
  , (2, Or  <$> genPredicate half <*> genPredicate half)
  , (1, Not <$> genPredicate (n - 1))
  ]
  where half = n `div` 2

-- | Generate an atomic (leaf) predicate — no boolean operators.
genAtomic :: Gen Predicate
genAtomic = oneof
  [ pure PTrue
  , pure PFalse
  , Equals             <$> arbitrary <*> arbitrary
  , NotEquals          <$> arbitrary <*> arbitrary
  , GreaterThan        <$> arbitrary <*> (NumberValue <$> genSafeDouble)
  , LessThan           <$> arbitrary <*> (NumberValue <$> genSafeDouble)
  , GreaterThanOrEqual <$> arbitrary <*> (NumberValue <$> genSafeDouble)
  , LessThanOrEqual    <$> arbitrary <*> (NumberValue <$> genSafeDouble)
  , Between <$> arbitrary
            <*> (NumberValue <$> genSafeDouble)
            <*> (NumberValue <$> genSafeDouble)
  , IsNull    <$> arbitrary
  , IsNotNull <$> arbitrary
  ]

-- | Generate a single (non-composite) action.
genSingleAction :: Gen Action
genSingleAction = oneof
  [ FlagFraud       <$> pickFrom safeStrings
  , AssignRiskScore <$> choose (0, 100)
  , RequireReview   <$> pickFrom safeStrings
  , RejectClaim     <$> pickFrom safeStrings
  , ApproveClaim    <$> pickFrom safeStrings
  ]

instance Arbitrary Action where
  arbitrary = oneof
    [ genSingleAction
    , CompositeAction <$> listOf1 genSingleAction
    ]
  shrink (CompositeAction [a])    = [a]
  shrink (CompositeAction (_:as)) = [CompositeAction as]
  shrink _                        = []

instance Arbitrary Rule where
  arbitrary = Rule
    <$> pickFrom safeRuleNames
    <*> pickFrom safeStrings   -- description
    <*> pure []                -- LET bindings omitted (separate concern)
    <*> arbitrary              -- condition
    <*> arbitrary              -- action
  shrink rule =
    [ rule { ruleCondition = p' } | p' <- shrink (ruleCondition rule) ]
    ++
    [ rule { ruleAction = a' }    | a' <- shrink (ruleAction rule) ]


-- ============================================================
-- Pretty-printer: AST → DSL text
--
-- This is the inverse of Claims.Parser. It must produce valid DSL text
-- that the parser reads back to the identical AST.
--
-- Key decisions:
--   * Explicit parentheses around every And/Or sub-expression — eliminates
--     all operator-precedence ambiguity during round-trips.
--   * NOT always followed by a parenthesized sub-expression.
--   * Only whole-number Doubles generated, so 'show' gives "42.0" not "4.2e1".
-- ============================================================

prettyFieldRef :: FieldRef -> Text
prettyFieldRef (Field t)               = t
prettyFieldRef (SegmentField seg f)    = seg <> "." <> f
prettyFieldRef (LoopField loop seg f)  = loop <> "." <> seg <> "." <> f
prettyFieldRef (ElementPosition _ _ _) = "amount"  -- not generated; safe fallback

prettyValue :: Value -> Text
prettyValue (StringValue t)    = "\"" <> t <> "\""
prettyValue (NumberValue n)    = T.pack (show n)
prettyValue (FieldRefValue fr) = prettyFieldRef fr  -- not generated
prettyValue (ListValue vs)     = "[" <> T.intercalate ", " (map prettyValue vs) <> "]"

prettyPredicate :: Predicate -> Text
prettyPredicate PTrue                    = "TRUE"
prettyPredicate PFalse                   = "FALSE"
prettyPredicate (Equals f v)             = prettyFieldRef f <> " = "  <> prettyValue v
prettyPredicate (NotEquals f v)          = prettyFieldRef f <> " != " <> prettyValue v
prettyPredicate (GreaterThan f v)        = prettyFieldRef f <> " > "  <> prettyValue v
prettyPredicate (LessThan f v)           = prettyFieldRef f <> " < "  <> prettyValue v
prettyPredicate (GreaterThanOrEqual f v) = prettyFieldRef f <> " >= " <> prettyValue v
prettyPredicate (LessThanOrEqual f v)    = prettyFieldRef f <> " <= " <> prettyValue v
prettyPredicate (IsNull f)               = prettyFieldRef f <> " IS NULL"
prettyPredicate (IsNotNull f)            = prettyFieldRef f <> " IS NOT NULL"
prettyPredicate (Between f lo hi)        =
  prettyFieldRef f <> " BETWEEN " <> prettyValue lo <> " AND " <> prettyValue hi
-- Explicit parentheses around both sides preserve round-trip correctness
prettyPredicate (And p1 p2) =
  "(" <> prettyPredicate p1 <> ") AND (" <> prettyPredicate p2 <> ")"
prettyPredicate (Or p1 p2)  =
  "(" <> prettyPredicate p1 <> ") OR ("  <> prettyPredicate p2 <> ")"
prettyPredicate (Not p)     =
  "NOT (" <> prettyPredicate p <> ")"
prettyPredicate _ = "TRUE"  -- unreachable: ungenerated constructors (HasDiagnosis, etc.)

prettyAction :: Action -> Text
prettyAction (FlagFraud reason)     = "FLAG_FRAUD \""     <> reason <> "\""
prettyAction (AssignRiskScore n)    = "RISK_SCORE "       <> T.pack (show n)
prettyAction (RequireReview note)   = "REQUIRE_REVIEW \"" <> note   <> "\""
prettyAction (RejectClaim reason)   = "REJECT \""         <> reason <> "\""
prettyAction (ApproveClaim reason)  = "APPROVE \""        <> reason <> "\""
prettyAction (CompositeAction acts) =
  "[" <> T.intercalate ", " (map prettyAction acts) <> "]"

prettyRule :: Rule -> Text
prettyRule rule =
  "RULE "  <> ruleName rule
  <> " \"" <> ruleDescription rule <> "\""
  <> " WHEN " <> prettyPredicate (ruleCondition rule)
  <> " THEN " <> prettyAction (ruleAction rule)
  <> ";"


-- ============================================================
-- Properties
-- ============================================================

-- | PROPERTY 1: Round-trip for a single rule.
--
-- For any randomly generated 'Rule', serializing it to DSL text and
-- parsing it back must yield the original rule unchanged.
--
-- This is the strongest test of parser/pretty-printer correctness.
prop_roundTrip :: Rule -> Property
prop_roundTrip rule =
  let text   = prettyRule rule
      result = parseRule text
  in counterexample
       ("Generated DSL text:\n  " <> T.unpack text)
       (result === Right rule)

-- | PROPERTY 2: Round-trip for two rules in sequence.
--
-- 'parseRules' parses multiple rules separated by whitespace.
-- This checks that rule boundaries are detected correctly and no rule
-- "bleeds" into the next one.
prop_twoRulesRoundTrip :: Rule -> Rule -> Property
prop_twoRulesRoundTrip r1 r2 =
  let text   = prettyRule r1 <> "\n" <> prettyRule r2
      result = parseRules text
  in counterexample
       ("Generated DSL text:\n  " <> T.unpack text)
       (result === Right [r1, r2])

-- | PROPERTY 3: Rule name is always preserved through serialization.
prop_ruleNamePreserved :: Rule -> Property
prop_ruleNamePreserved rule =
  case parseRule (prettyRule rule) of
    Left  err   -> counterexample (show err) False
    Right rule' -> ruleName rule' === ruleName rule

-- | PROPERTY 4: Rule description is always preserved through serialization.
prop_descriptionPreserved :: Rule -> Property
prop_descriptionPreserved rule =
  case parseRule (prettyRule rule) of
    Left  err   -> counterexample (show err) False
    Right rule' -> ruleDescription rule' === ruleDescription rule


-- ============================================================
-- Hspec integration
-- ============================================================

parserProperties :: Spec
parserProperties =
  describe "Parser — Property Tests (QuickCheck)" $ do

    describe "Round-trip: prettyPrint >>> parseRule === pure" $ do

      it "single rule survives serialize → parse" $
        checkProp prop_roundTrip

      it "two rules in sequence both survive" $
        checkProp prop_twoRulesRoundTrip

    describe "Structural invariants (individual fields)" $ do

      it "rule name is always preserved" $
        checkProp prop_ruleNamePreserved

      it "rule description is always preserved" $
        checkProp prop_descriptionPreserved
