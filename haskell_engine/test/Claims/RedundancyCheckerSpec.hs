{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.RedundancyChecker".
module Claims.RedundancyCheckerSpec (redundancyCheckerSpec) where

import Test.Hspec
import Claims.RedundancyChecker
import Claims.Syntax
import Prelude hiding (EQ, GT, LT)

redundancyCheckerSpec :: Spec
redundancyCheckerSpec = do
  describe "RedundancyChecker" $ do
    let mkRule name cond act = Rule name "" [] cond act

    it "detects exact duplicate (same condition and action, different name)" $ do
      let ruleA = mkRule "rule_a" (Compare GT (Path ["financial", "claim_amount"]) (NumberValue 50000)) (RequireReview "high value")
          ruleB = mkRule "rule_b" (Compare GT (Path ["financial", "claim_amount"]) (NumberValue 50000)) (RequireReview "high value")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ExactDuplicate

    it "detects exact duplicate with commutative AND" $ do
      let condA = And (Compare EQ (Path ["state"]) (StringValue "CA")) (Compare GT (Path ["amount"]) (NumberValue 1000))
          condB = And (Compare GT (Path ["amount"]) (NumberValue 1000)) (Compare EQ (Path ["state"]) (StringValue "CA"))
          ruleA = mkRule "rule_a" condA (FlagFraud "test")
          ruleB = mkRule "rule_b" condB (FlagFraud "test")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ExactDuplicate

    it "detects condition overlap on same field with overlapping numeric ranges" $ do
      -- > 40000 vs < 60000: ranges overlap but neither implies the other
      let ruleA = mkRule "rule_a" (Compare GT (Path ["amount"]) (NumberValue 40000)) (RequireReview "review 40k")
          ruleB = mkRule "rule_b" (Compare LT (Path ["amount"]) (NumberValue 60000)) (FlagFraud "low amount")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ConditionOverlap

    it "detects shadowed: broader rule subsumes narrower with different action" $ do
      let ruleA = mkRule "broad" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "high")
          ruleB = mkRule "narrow" (And (Compare GT (Path ["amount"]) (NumberValue 50000)) (Compare EQ (Path ["state"]) (StringValue "CA"))) (FlagFraud "ca high")
          matches = checkRedundancy ruleB [ruleA]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Shadowed

    it "detects subsumption with same action (truly redundant)" $ do
      let ruleA = mkRule "broad" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "high")
          ruleB = mkRule "narrow" (And (Compare GT (Path ["amount"]) (NumberValue 50000)) (Compare EQ (Path ["state"]) (StringValue "CA"))) (RequireReview "high")
          matches = checkRedundancy ruleB [ruleA]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Subsumption

    it "no match for completely different fields" $ do
      let ruleA = mkRule "rule_a" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "amount")
          ruleB = mkRule "rule_b" (Compare EQ (Path ["state"]) (StringValue "CA")) (RequireReview "state")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "detects subsumption with numeric tightening (> 60000 implies > 50000, different message)" $ do
      let ruleA = mkRule "stricter" (Compare GT (Path ["amount"]) (NumberValue 60000)) (RequireReview "60k")
          ruleB = mkRule "looser" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "50k")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Subsumption
      matchExplanation (head matches)
        `shouldBe` "'stricter' is more specific than 'looser' — existing rule covers all cases this rule would match"

    it "same condition and action with a different message is a duplicate, not a conflict" $ do
      let cond = Compare GT (Path ["amount"]) (NumberValue 50000)
          ruleA = mkRule "rule_a" cond (FlagFraud "over 50k")
          ruleB = mkRule "rule_b" cond (FlagFraud "claim exceeds $50,000")
          matches = checkRedundancy ruleA [ruleB]
      map matchLevel matches `shouldBe` [ExactDuplicate]
      matchExplanation (head matches)
        `shouldBe` "Same condition and action as 'rule_b'; only the message differs"

    it "different risk scores are different actions" $ do
      let ruleA = mkRule "stricter" (Compare GT (Path ["amount"]) (NumberValue 60000)) (AssignRiskScore 90)
          ruleB = mkRule "looser" (Compare GT (Path ["amount"]) (NumberValue 50000)) (AssignRiskScore 50)
      map matchLevel (checkRedundancy ruleA [ruleB]) `shouldBe` [Shadowed]

    it "composite actions compare as sets of outcomes" $ do
      let ruleA = mkRule "stricter" (Compare GT (Path ["amount"]) (NumberValue 60000))
                    (CompositeAction [FlagFraud "a", RequireReview "b"])
          ruleB = mkRule "looser" (Compare GT (Path ["amount"]) (NumberValue 50000))
                    (CompositeAction [RequireReview "c", FlagFraud "d"])
          ruleC = mkRule "other" (Compare GT (Path ["amount"]) (NumberValue 50000))
                    (CompositeAction [RequireReview "c", RejectClaim "d"])
      map matchLevel (checkRedundancy ruleA [ruleB]) `shouldBe` [Subsumption]
      map matchLevel (checkRedundancy ruleA [ruleC]) `shouldBe` [Shadowed]

    it "detects shadowed between two AND rules (stricter amount, same state)" $ do
      let stateNY = Compare EQ (Path ["state"]) (StringValue "NY")
          ruleA = mkRule "stricter" (And (Compare GT (Path ["amount"]) (NumberValue 1000)) stateNY) (FlagFraud "ny high")
          ruleB = mkRule "looser" (And (Compare GT (Path ["amount"]) (NumberValue 500)) stateNY) (RequireReview "ny")
      map matchLevel (checkRedundancy ruleA [ruleB]) `shouldBe` [Shadowed]
      map matchLevel (checkRedundancy ruleB [ruleA]) `shouldBe` [Shadowed]

    it "strict bounds on the same value do not overlap (> 5 vs < 5)" $ do
      let ruleA = mkRule "above" (Compare GT (Path ["amount"]) (NumberValue 5)) (FlagFraud "above")
          ruleB = mkRule "below" (Compare LT (Path ["amount"]) (NumberValue 5)) (RequireReview "below")
      checkRedundancy ruleA [ruleB] `shouldBe` []

    it "a strict bound excludes an equal value (> 5 vs = 5)" $ do
      let ruleA = mkRule "above" (Compare GT (Path ["amount"]) (NumberValue 5)) (FlagFraud "above")
          ruleB = mkRule "five" (Compare EQ (Path ["amount"]) (NumberValue 5)) (RequireReview "five")
      checkRedundancy ruleA [ruleB] `shouldBe` []

    it "inclusive bounds on the same value overlap (>= 5 vs <= 5)" $ do
      let ruleA = mkRule "atLeast" (Compare GTE (Path ["amount"]) (NumberValue 5)) (FlagFraud "at least")
          ruleB = mkRule "atMost" (Compare LTE (Path ["amount"]) (NumberValue 5)) (RequireReview "at most")
      map matchLevel (checkRedundancy ruleA [ruleB]) `shouldBe` [ConditionOverlap]

    it "disjoint BETWEEN ranges do not overlap (1-5 vs 7-14)" $ do
      let short = mkRule "short" (Between (Path ["days_stay"]) (NumberValue 1) (NumberValue 5)) (RequireReview "short")
          medium = mkRule "medium" (Between (Path ["days_stay"]) (NumberValue 7) (NumberValue 14)) (RequireReview "medium")
      checkRedundancy short [medium] `shouldBe` []
      checkRedundancy medium [short] `shouldBe` []

    it "intersecting BETWEEN ranges overlap (7-14 vs 10-21)" $ do
      let medium = mkRule "medium" (Between (Path ["days_stay"]) (NumberValue 7) (NumberValue 14)) (RequireReview "medium")
          long = mkRule "long" (Between (Path ["days_stay"]) (NumberValue 10) (NumberValue 21)) (FlagFraud "long")
      map matchLevel (checkRedundancy long [medium]) `shouldBe` [ConditionOverlap]

    it "a range above a BETWEEN does not overlap it (> 14 vs 7-14)" $ do
      let medium = mkRule "medium" (Between (Path ["days_stay"]) (NumberValue 7) (NumberValue 14)) (RequireReview "medium")
          longStay =
            mkRule "long_stay_high_amount"
              (And (Compare GT (Path ["amount"]) (NumberValue 50000)) (Compare GT (Path ["days_stay"]) (NumberValue 14)))
              (RequireReview "long")
      checkRedundancy longStay [medium] `shouldBe` []

    it "a rule's own bounds on a field are combined (5 < x < 10 vs x > 20)" $ do
      let band = mkRule "band" (And (Compare GT (Path ["x"]) (NumberValue 5)) (Compare LT (Path ["x"]) (NumberValue 10))) (FlagFraud "band")
          high = mkRule "high" (Compare GT (Path ["x"]) (NumberValue 20)) (RequireReview "high")
      checkRedundancy band [high] `shouldBe` []
      checkRedundancy high [band] `shouldBe` []

    it "different equality values on a field do not overlap" $ do
      let ruleA = mkRule "ca" (And (Compare EQ (Path ["state"]) (StringValue "CA")) (Compare GT (Path ["x"]) (NumberValue 1))) (FlagFraud "ca")
          ruleB = mkRule "ny" (And (Compare EQ (Path ["state"]) (StringValue "NY")) (Compare LT (Path ["x"]) (NumberValue 0))) (RequireReview "ny")
      checkRedundancy ruleA [ruleB] `shouldBe` []

    it "same condition with a different action is reported as a conflict, not as 'more specific'" $ do
      let cond = Compare EQ (Path ["diagnosis_code"]) (StringValue "E11.9")
          flag = mkRule "diabetes_flag" cond (FlagFraud "flag")
          reject = mkRule "diabetes_reject" cond (RejectClaim "reject")
          matches = checkRedundancy reject [flag]
      map matchLevel matches `shouldBe` [Shadowed]
      matchExplanation (head matches)
        `shouldBe` "Same condition as 'diabetes_flag' but a different action — conflict"

    it "NOT does not produce false overlap" $ do
      let ruleA = mkRule "rule_a" (Not (Compare GT (Path ["amount"]) (NumberValue 50000))) (RequireReview "low")
          ruleB = mkRule "rule_b" (Compare GT (Path ["amount"]) (NumberValue 40000)) (FlagFraud "high")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "!= does not produce false overlap" $ do
      let ruleA = mkRule "rule_a" (Compare NE (Path ["status"]) (StringValue "approved")) (RequireReview "not approved")
          ruleB = mkRule "rule_b" (Compare GT (Path ["status"]) (NumberValue 0)) (FlagFraud "positive")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "returns most specific level only (exact dup wins over overlap)" $ do
      let ruleA = mkRule "rule_a" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "same")
          ruleB = mkRule "rule_b" (Compare GT (Path ["amount"]) (NumberValue 50000)) (RequireReview "same")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ExactDuplicate

  -- ----------------------------------------------------------------
  -- New DSL Features
  -- ----------------------------------------------------------------
