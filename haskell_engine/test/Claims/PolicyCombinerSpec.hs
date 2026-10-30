{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.PolicyCombiner".
module Claims.PolicyCombinerSpec (policyCombinerSpec) where

import Data.String (fromString)
import Test.Hspec
import Claims.MLClient
import Claims.PolicyCombiner
import Claims.Syntax
import Prelude hiding (EQ, GT, LT)

policyCombinerSpec :: Spec
policyCombinerSpec = do
  describe "PolicyCombiner" $ do
    it "DSL reject always wins even with low ML risk" $ do
      let rules = [mkResult "reject_rule" True (Just (RejectClaim "hard reject")) "reject"]
          ml = mlStubResult {mlRiskScore = Just 0.10}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_1" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REJECT"
      queue (decision out) `shouldBe` "denied"

    it "ML high risk escalates to fraud priority for non-reject outcomes" $ do
      let rules = [mkResult "review_rule" True (Just (RequireReview "review")) "review"]
          ml = mlStubResult {mlRiskScore = Just 0.85}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_2" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "fraud_priority"

    it "ML error falls back to DSL-only path" $ do
      let rules = []
          out = buildCombinedEnvelope defaultPolicyConfig "claim_3" "2026-02-20T00:00:00Z" rules (mlErrorResult "timeout")
      status (decision out) `shouldBe` "APPROVE"
      queue (decision out) `shouldBe` "none"

    it "ML cannot auto-reject when DSL does not reject" $ do
      let rules = []
          ml = mlStubResult {mlRiskScore = Just 0.99}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_4" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "siu_escalation"

    it "exact T_low boundary routes to manual review" $ do
      let rules = []
          ml = mlStubResult {mlRiskScore = Just 0.35}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_low_boundary" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "manual_review"

    it "exact T_high boundary routes to fraud priority" $ do
      let rules = []
          ml = mlStubResult {mlRiskScore = Just 0.80}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_high_boundary" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "fraud_priority"

    it "exact T_siu boundary routes to SIU escalation" $ do
      let rules = []
          ml = mlStubResult {mlRiskScore = Just 0.93}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_siu_boundary" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "siu_escalation"

mkResult :: String -> Bool -> Maybe Action -> String -> RuleResult
mkResult name matched action details =
  RuleResult
    { resultRuleName = fromString name,
      resultMatched = matched,
      resultAction = action,
      resultDetails = fromString details,
      resultUndecided = False
    }
