{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.String (fromString)
import Test.Hspec
import X12.DSL.EvaluationContract
import X12.DSL.MLClient
import X12.DSL.Parser
import X12.DSL.PolicyCombiner
import X12.DSL.SimpleEvaluator (evaluateRuleSimple)
import X12.DSL.Syntax
import X12.DSL.X12Types

main :: IO ()
main = hspec $ do
  describe "DSL Parser" $ do
    it "parses simple equality predicate" $ do
      let input = "RULE test \"Test rule\" WHEN field = \"value\" THEN FLAG_FRAUD \"test\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          ruleName rule `shouldBe` "test"
          ruleDescription rule `shouldBe` "Test rule"

    it "parses numeric comparison" $ do
      let input = "RULE test \"Test\" WHEN amount > 100.0 THEN RISK_SCORE 50;"
      parseRule input `shouldSatisfy` isRight

    it "parses complex AND expression" $ do
      let input = "RULE test \"Test\" WHEN field1 = \"a\" AND field2 > 10.0 THEN REJECT \"fail\";"
      parseRule input `shouldSatisfy` isRight

    it "parses OR expression" $ do
      let input = "RULE test \"Test\" WHEN a = \"x\" OR b = \"y\" THEN RISK_SCORE 30;"
      parseRule input `shouldSatisfy` isRight

    it "parses NOT expression" $ do
      let input = "RULE test \"Test\" WHEN NOT field = \"bad\" THEN FLAG_FRAUD \"negation test\";"
      parseRule input `shouldSatisfy` isRight

    it "parses nested boolean expressions" $ do
      let input = "RULE test \"Test\" WHEN (a = \"1\" OR b = \"2\") AND c > 10.0 THEN RISK_SCORE 50;"
      parseRule input `shouldSatisfy` isRight

    it "parses composite actions" $ do
      let input = "RULE test \"Test\" WHEN x = \"y\" THEN [FLAG_FRAUD \"reason\", RISK_SCORE 75];"
      parseRule input `shouldSatisfy` isRight

    it "parses segment-qualified field references" $ do
      let input = "RULE test \"Test\" WHEN CLM.amount > 1000.0 THEN FLAG_FRAUD \"high claim\";"
      parseRule input `shouldSatisfy` isRight

    it "parses loop-qualified field references" $ do
      let input = "RULE test \"Test\" WHEN 2300.CLM.amount > 5000.0 THEN REQUIRE_REVIEW \"review\";"
      parseRule input `shouldSatisfy` isRight

    it "parses multiple rules" $ do
      let input = "RULE r1 \"First\" WHEN TRUE THEN RISK_SCORE 10; RULE r2 \"Second\" WHEN FALSE THEN RISK_SCORE 20;"
      case parseRules input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rules -> length rules `shouldBe` 2

    it "parses LET bindings before WHEN" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          length (ruleBindings rule) `shouldBe` 1
          bindingName (head (ruleBindings rule)) `shouldBe` "amount"

    it "rejects duplicate LET binding names" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount LET amount = claim.other WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      parseRule input `shouldSatisfy` isLeft

    it "evaluates predicates using LET bindings" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (1500 :: Int)]]
              result = evaluateRuleSimple doc rule
          resultMatched result `shouldBe` True

    it "parses helper-call predicates" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_weekend(claim.service_date) THEN REQUIRE_REVIEW \"weekend\";"
      parseRule input `shouldSatisfy` isRight

    it "evaluates is_weekend helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_weekend(claim.service_date) THEN REQUIRE_REVIEW \"weekend\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2026-02-22" :: String)]]
              result = evaluateRuleSimple doc rule
          resultMatched result `shouldBe` True

    it "evaluates is_high_amount helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_high_amount(claim.amount, 50000) THEN FLAG_FRAUD \"high amount\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (75000 :: Int)]]
              result = evaluateRuleSimple doc rule
          resultMatched result `shouldBe` True

    it "evaluates in_list helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN in_list(claim.state, [\"NY\", \"CA\"]) THEN REQUIRE_REVIEW \"state\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["state" .= ("CA" :: String)]]
              result = evaluateRuleSimple doc rule
          resultMatched result `shouldBe` True

  describe "PolicyCombiner" $ do
    it "DSL reject always wins even with low ML risk" $ do
      let rules = [mkResult "reject_rule" True (Just (RejectClaim' "hard reject")) "reject"]
          ml = mlStubResult {mlRiskScore = Just 0.10}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_1" "2026-02-20T00:00:00Z" rules ml
      status (decision out) `shouldBe` "REJECT"
      queue (decision out) `shouldBe` "denied"

    it "ML high risk escalates to fraud priority for non-reject outcomes" $ do
      let rules = [mkResult "review_rule" True (Just (RequireReview' "review")) "review"]
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

  describe "MLClient parser" $ do
    it "parses contract-style risk_score" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double), "confidence" .= (0.77 :: Double)],
                "top_factors" .= [object ["feature" .= ("f1" :: String), "direction" .= ("up" :: String), "contribution" .= (0.2 :: Double)]]
              ]
      case parseMlResultFromValue payload of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right res -> do
          mlRiskScore res `shouldBe` Just 0.83
          mlStatus res `shouldBe` "ok"

    it "parses fallback ml_probability when risk_score missing" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["ml_probability" .= (0.61 :: Double)]
              ]
      case parseMlResultFromValue payload of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right res -> mlRiskScore res `shouldBe` Just 0.61

    it "rejects missing contract_version" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects unsupported contract_version" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("2.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects missing required scores block for ok status" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects missing required model fields for ok status" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

  describe "Evaluation request contract" $ do
    it "accepts valid evaluate request contract payload" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonSuccess

    it "rejects missing request_id" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

    it "rejects unsupported request contract_version" $ do
      let payload =
            object
              [ "contract_version" .= ("2.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

    it "rejects empty tenant_id" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("   " :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isAesonSuccess :: Aeson.Result a -> Bool
isAesonSuccess (Aeson.Success _) = True
isAesonSuccess _ = False

isAesonError :: Aeson.Result a -> Bool
isAesonError (Aeson.Error _) = True
isAesonError _ = False

mkResult :: String -> Bool -> Maybe Action' -> String -> RuleResult
mkResult name matched action details =
  RuleResult
    { resultRuleName = fromString name,
      resultMatched = matched,
      resultAction = action,
      resultDetails = fromString details
    }
