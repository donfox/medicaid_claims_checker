{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : ParserProps
-- Description : QuickCheck property tests for Claims.Parser
--
-- This module demonstrates property-based testing applied to the DSL parser.
-- Instead of writing specific example inputs, we:
--
--   1. Define 'Arbitrary' instances that generate random AST values
--   2. Render them back to DSL text with "Claims.Pretty"
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

import Prelude hiding (EQ, GT, LT)
import qualified Data.Text as T
import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Claims.Parser (parseRule, parseRules)
import Claims.Pretty (prettyRule, prettyRules)
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

safeLetNames :: [Text]
safeLetNames = ["amt", "prov", "svc_date"]

safeHelpers :: [Text]
safeHelpers = ["is_weekend", "in_list", "starts_with"]

-- | Valid POSIX extended patterns of the kind analysts write.
safePatterns :: [Text]
safePatterns = ["^[0-9]{10}$", "^99[0-9]{3}$", "E11\\.[0-9]+", "^(A|B)[0-9]*$", "x"]

-- | Pick a random element from a fixed list.
pickFrom :: [a] -> Gen a
pickFrom = elements

-- | Generate a Double with up to two decimal places, positive or negative
-- (e.g. 42.0, -0.05, 1234.5). 'Claims.Pretty' never uses scientific
-- notation, so small and fractional values round-trip too.
genSafeDouble :: Gen Double
genSafeDouble = (/ 100) . fromIntegral <$> choose (-999999 :: Int, 999999)

genSegmentPath :: Gen SegmentPath
genSegmentPath = SegmentPath <$> pickFrom safeLoops <*> (take 1 <$> sublistOf safeSegments)

-- | A literal: no field references, since list elements must be scalars.
genScalar :: Gen Value
genScalar = oneof [StringValue <$> pickFrom safeStrings, NumberValue <$> genSafeDouble]


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
  arbitrary = frequency
    [ (4, genScalar)
    , (1, FieldRefValue <$> arbitrary)
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
  shrink (Exists v path p) = p : [Exists v path p' | p' <- shrink p]
  shrink (ForAll v path p) = p : [ForAll v path p' | p' <- shrink p]
  shrink _           = []

genPredicate :: Int -> Gen Predicate
genPredicate 0 = genAtomic
genPredicate n = frequency
  [ (5, genAtomic)
  , (2, And <$> genPredicate half <*> genPredicate half)
  , (2, Or  <$> genPredicate half <*> genPredicate half)
  , (1, Not <$> genPredicate (n - 1))
  , (1, Exists <$> genVar <*> genSegmentPath <*> genPredicate half)
  , (1, ForAll <$> genVar <*> genSegmentPath <*> genPredicate half)
  ]
  where
    half = n `div` 2
    genVar = oneof [pure Nothing, Just <$> pickFrom ["line", "item"]]

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
  , Contains  <$> arbitrary <*> (StringValue <$> pickFrom safeStrings)
  , Matches   <$> arbitrary <*> pickFrom safePatterns
  , HasDiagnosis <$> genScalar
  , HasProcedure <$> genScalar
  , Count <$> genSegmentPath <*> elements [EQ, NE, GT, LT, GTE, LTE] <*> choose (0, 50)
  , HelperCall <$> pickFrom safeHelpers
               <*> listOf (oneof [arbitrary, ListValue <$> listOf1 genScalar])
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
    <*> genBindings
    <*> arbitrary              -- condition
    <*> arbitrary              -- action
  shrink rule =
    [ rule { ruleCondition = p' } | p' <- shrink (ruleCondition rule) ]
    ++
    [ rule { ruleAction = a' }    | a' <- shrink (ruleAction rule) ]
    ++
    [ rule { ruleBindings = [] } | not (null (ruleBindings rule)) ]

-- | Zero or more LET bindings with distinct names (duplicates are a parse error).
genBindings :: Gen [Binding]
genBindings = do
  names <- sublistOf safeLetNames
  traverse (\name -> Binding name <$> arbitrary) names


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

-- | PROPERTY 2b: 'prettyRules' output parses back to the same rule set.
prop_ruleSetRoundTrip :: [Rule] -> Property
prop_ruleSetRoundTrip rules =
  let text = prettyRules rules
  in counterexample ("Generated DSL text:\n" <> T.unpack text)
       (parseRules text === Right rules)

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

      it "a whole rule set survives prettyRules → parseRules" $
        checkProp prop_ruleSetRoundTrip

    describe "Structural invariants (individual fields)" $ do

      it "rule name is always preserved" $
        checkProp prop_ruleNamePreserved

      it "rule description is always preserved" $
        checkProp prop_descriptionPreserved
