{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (evaluate)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.String (fromString)
import Data.Time (Day, fromGregorian)
import Test.Hspec
import BusinessRulesSpec (businessRulesSpec)
import ListenConfigSpec (listenConfigSpec)
import ParserProps (parserProperties)
import Claims.Pipeline (EvaluationRequest (..))
import Claims.Evaluator (EvaluationReport (..), RiskLevel (..), evaluateRuleSimple, evaluateSimpleJson)
import Claims.MLClient
import Claims.Parser
import Claims.PolicyCombiner
import Claims.RedundancyChecker
import Claims.Syntax
import Prelude hiding (EQ, GT, LT)

-- | Fixed test date: 2026-02-28 (Saturday)
testDay :: Day
testDay = fromGregorian 2026 2 28

main :: IO ()
main = hspec $ do
  businessRulesSpec
  listenConfigSpec
  parserProperties
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
              result = evaluateRuleSimple testDay doc rule
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
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "evaluates is_high_amount helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_high_amount(claim.amount, 50000) THEN FLAG_FRAUD \"high amount\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (75000 :: Int)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "evaluates in_list helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN in_list(claim.state, [\"NY\", \"CA\"]) THEN REQUIRE_REVIEW \"state\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["state" .= ("CA" :: String)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

  describe "Text predicates" $ do
    let npiDoc npi = object ["provider" .= object ["npi" .= (npi :: String)]]
        evalOn doc input = case parseRule input of
          Left err -> error ("Parse failed: " ++ show err)
          Right rule -> resultMatched (evaluateRuleSimple testDay doc rule)

    it "CONTAINS matches a substring" $ do
      let input = "RULE c \"d\" WHEN provider.npi CONTAINS \"234\" THEN REQUIRE_REVIEW \"x\";"
      evalOn (npiDoc "1234567890") input `shouldBe` True
      evalOn (npiDoc "9999999999") input `shouldBe` False

    it "MATCHES anchors ^ and $ to the whole value" $ do
      let input = "RULE m \"d\" WHEN NOT (provider.npi MATCHES \"^[0-9]{10}$\") THEN REJECT \"bad npi\";"
      evalOn (npiDoc "1234567890") input `shouldBe` False
      evalOn (npiDoc "12345") input `shouldBe` True
      evalOn (npiDoc "12345678901") input `shouldBe` True

    it "MATCHES is an unanchored search without ^ / $" $ do
      let input = "RULE m \"d\" WHEN provider.npi MATCHES \"99\" THEN REQUIRE_REVIEW \"x\";"
      evalOn (npiDoc "1299345678") input `shouldBe` True

    it "MATCHES on a missing field does not match" $ do
      let input = "RULE m \"d\" WHEN provider.taxonomy MATCHES \".*\" THEN REQUIRE_REVIEW \"x\";"
      evalOn (npiDoc "1234567890") input `shouldBe` False

    it "rejects an invalid regex at parse time" $ do
      let input = "RULE m \"d\" WHEN provider.npi MATCHES \"([0-9]\" THEN REJECT \"x\";"
      parseRule input `shouldSatisfy` isLeft

  describe "RuleResult JSON wire format" $ do
    let composite =
          mkResult "r" True (Just (CompositeAction [RejectClaim "dup", AssignRiskScore 90])) "matched"
        expected =
          object
            [ "resultRuleName" .= ("r" :: String),
              "resultMatched" .= True,
              "resultAction"
                .= object
                  [ "tag" .= ("CompositeAction'" :: String),
                    "contents"
                      .= [ object ["tag" .= ("RejectClaim'" :: String), "contents" .= ("dup" :: String)],
                           object ["tag" .= ("AssignRiskScore'" :: String), "contents" .= (90 :: Int)]
                         ]
                  ],
              "resultDetails" .= ("matched" :: String),
              "resultUndecided" .= False
            ]

    it "keeps the primed action tags Phoenix and stored reports rely on" $
      Aeson.toJSON composite `shouldBe` expected

    it "decodes its own encoding" $
      Aeson.fromJSON (Aeson.toJSON composite) `shouldBe` Aeson.Success composite

    it "encodes an unmatched result's action as null" $
      Aeson.toJSON (mkResult "r" False Nothing "no")
        `shouldBe` object
          [ "resultRuleName" .= ("r" :: String),
            "resultMatched" .= False,
            "resultAction" .= Aeson.Null,
            "resultDetails" .= ("no" :: String),
            "resultUndecided" .= False
          ]

    it "decodes a stored result that has no resultUndecided field" $
      Aeson.fromJSON
        ( object
            [ "resultRuleName" .= ("r" :: String),
              "resultMatched" .= False,
              "resultAction" .= Aeson.Null,
              "resultDetails" .= ("no" :: String)
            ]
        )
        `shouldBe` Aeson.Success (mkResult "r" False Nothing "no")

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

  -- ----------------------------------------------------------------
  -- Claim Scenarios
  -- ----------------------------------------------------------------
  -- Four BA rules that match the seeded business rules.
  -- Two extra rules (extreme_amount, impossible_date) emulate the
  -- Default Rule catalogue entries ImpossibleDates / ExtremeAmounts.
  let claimRulesText =
        -- BA Rule 1 — seed: HighValueReview
        "RULE high_value_review \"Flag high-value claims for manual review\" \
        \WHEN 2300.CLM.claim_amount > 50000 \
        \THEN REQUIRE_REVIEW \"Exceeds high-value threshold\"; \
        \RULE weekend_office_visit \"Office visit on weekend with elevated amount\" \
        \WHEN 2400.SV1.place_of_service = \"11\" \
        \AND 2400.DTP.service_day_of_week = \"SAT\" \
        \AND 2300.CLM.claim_amount > 500 \
        \THEN REQUIRE_REVIEW \"Weekend office visit requires verification\"; \
        \RULE inpatient_mismatch \"Outpatient POS with inpatient billing\" \
        \WHEN 2400.SV1.place_of_service = \"22\" \
        \AND 2300.CLM.facility_type = \"Inpatient\" \
        \AND 2300.CLM.claim_amount > 10000 \
        \THEN REJECT \"Inpatient/outpatient mismatch detected\"; \
        \RULE extreme_amount \"Flag extreme billing amounts (Default Rule equivalent)\" \
        \WHEN 2300.CLM.claim_amount > 1000000 \
        \THEN FLAG_FRAUD \"Extreme billing amount exceeds $1M\";"

  let Right claimEngine = loadRules claimRulesText

  -- Helper: build an X12-structured JSON claim document
  let mkX12Claim amount pos dow facilityType =
        object
          [ "2300"
              .= object
                [ "CLM"
                    .= object
                      [ "claim_amount" .= (amount :: Double)
                      , "facility_type" .= (facilityType :: String)
                      ]
                ]
          , "2400"
              .= object
                [ "SV1" .= object ["place_of_service" .= (pos :: String)]
                , "DTP" .= object ["service_day_of_week" .= (dow :: String)]
                ]
          ]

  let evalTs = "2026-02-24T00:00:00Z"

  describe "Claim Scenarios — BA Rules (10 claim types)" $ do
    it "CLM001 valid claim ($1500, Outpatient, Tue): no rules fire" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1500 "11" "TUE" "Outpatient")
      reportMatchedRules report `shouldBe` 0
      reportOverallRisk report `shouldBe` LowRisk

    it "CLM002 high value ($75k, Tue): high_value_review fires → REQUIRE_REVIEW" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 75000 "11" "TUE" "Outpatient")
      reportMatchedRules report `shouldBe` 1
      -- REQUIRE_REVIEW asks for analyst review, so the claim is HighRisk
      reportOverallRisk report `shouldBe` HighRisk

    it "CLM003 weekend office visit ($800, pos=11, SAT): weekend_office_visit fires" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 800 "11" "SAT" "Outpatient")
      reportMatchedRules report `shouldBe` 1

    it "CLM004 inpatient mismatch ($15k, pos=22, Inpatient): REJECT → CriticalRisk" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 15000 "22" "MON" "Inpatient")
      reportMatchedRules report `shouldBe` 1
      reportOverallRisk report `shouldBe` CriticalRisk

    it "CLM005 extreme amount ($1.5M): FLAG_FRAUD → CriticalRisk (also triggers high_value)" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1500000 "11" "MON" "Outpatient")
      -- extreme_amount AND high_value_review both match
      reportMatchedRules report `shouldBe` 2
      reportOverallRisk report `shouldBe` CriticalRisk

    it "CLM006 high value + weekend office ($60k, pos=11, SAT): two rules match" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 60000 "11" "SAT" "Outpatient")
      reportMatchedRules report `shouldBe` 2

    it "CLM007 weekend but wrong POS code (pos=21, SAT, $800): no rules match" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 800 "21" "SAT" "Outpatient")
      reportMatchedRules report `shouldBe` 0

    it "CLM008 inpatient low amount ($5k, pos=22, Inpatient): below $10k threshold, no match" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 5000 "22" "MON" "Inpatient")
      reportMatchedRules report `shouldBe` 0

    it "CLM009 compound: high value + inpatient mismatch ($75k, pos=22, Inpatient) → CriticalRisk" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 75000 "22" "MON" "Inpatient")
      -- high_value_review + inpatient_mismatch
      reportMatchedRules report `shouldBe` 2
      reportOverallRisk report `shouldBe` CriticalRisk

    it "CLM010 triple violation ($1.2M, pos=22, Inpatient): extreme + high_value + inpatient → CriticalRisk" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1200000 "22" "MON" "Inpatient")
      -- high_value_review + inpatient_mismatch + extreme_amount
      reportMatchedRules report `shouldBe` 3
      reportOverallRisk report `shouldBe` CriticalRisk

  describe "Claim Scenarios — DSL + ML Model Combined" $ do
    it "CLM011 clean claim + ML low risk (0.10): APPROVE" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1500 "11" "TUE" "Outpatient")
          ml = mlStubResult {mlRiskScore = Just 0.10}
          out = buildCombinedEnvelope defaultPolicyConfig "CLM011" evalTs (reportResults report) ml
      status (decision out) `shouldBe` "APPROVE"
      queue (decision out) `shouldBe` "none"

    it "CLM012 clean claim + ML medium risk (0.55): REQUIRE_REVIEW (manual_review queue)" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1500 "11" "TUE" "Outpatient")
          ml = mlStubResult {mlRiskScore = Just 0.55}
          out = buildCombinedEnvelope defaultPolicyConfig "CLM012" evalTs (reportResults report) ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "manual_review"

    it "CLM013 high value claim (DSL REQUIRE_REVIEW) + ML high risk (0.85): fraud_priority queue" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 75000 "11" "TUE" "Outpatient")
          ml = mlStubResult {mlRiskScore = Just 0.85}
          out = buildCombinedEnvelope defaultPolicyConfig "CLM013" evalTs (reportResults report) ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "fraud_priority"

    it "CLM014 inpatient mismatch (DSL REJECT) + ML low risk (0.10): REJECT wins over ML" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 15000 "22" "MON" "Inpatient")
          ml = mlStubResult {mlRiskScore = Just 0.10}
          out = buildCombinedEnvelope defaultPolicyConfig "CLM014" evalTs (reportResults report) ml
      status (decision out) `shouldBe` "REJECT"
      queue (decision out) `shouldBe` "denied"

    it "CLM015 clean claim + ML very high risk (0.95): REQUIRE_REVIEW (siu_escalation queue)" $ do
      let report = evaluateSimpleJson claimEngine testDay (mkX12Claim 1500 "11" "TUE" "Outpatient")
          ml = mlStubResult {mlRiskScore = Just 0.95}
          out = buildCombinedEnvelope defaultPolicyConfig "CLM015" evalTs (reportResults report) ml
      status (decision out) `shouldBe` "REQUIRE_REVIEW"
      queue (decision out) `shouldBe` "siu_escalation"

  describe "Claim Scenarios — Helper Functions" $ do
    it "is_weekend helper: detects Saturday service date" $ do
      let input =
            "RULE weekend_service \"Flag weekend service dates\" \
            \WHEN is_weekend(claim.service_date) \
            \THEN REQUIRE_REVIEW \"Weekend service\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2026-02-21" :: String)]] -- Saturday
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "is_weekend helper: weekday service date does not match" $ do
      let input =
            "RULE weekend_service \"Flag weekend service dates\" \
            \WHEN is_weekend(claim.service_date) \
            \THEN REQUIRE_REVIEW \"Weekend service\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2026-02-24" :: String)]] -- Tuesday
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` False

    it "in_list helper: flags high-fraud diagnosis codes" $ do
      let input =
            "RULE suspicious_dx \"Flag suspicious diagnosis codes\" \
            \WHEN in_list(claim.dx_code, [\"Z76.89\", \"Z09\", \"V70.3\"]) \
            \THEN FLAG_FRAUD \"Suspicious diagnosis code\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["dx_code" .= ("Z76.89" :: String)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "is_high_amount helper: flags claims above custom threshold" $ do
      let input =
            "RULE high_amount \"Custom high amount threshold\" \
            \WHEN is_high_amount(claim.amount, 100000) \
            \THEN REQUIRE_REVIEW \"Above custom threshold\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (125000 :: Int)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

  -- ----------------------------------------------------------------
  -- Extended Claim Scenarios — 6 new rules + 6 new claim types
  -- ----------------------------------------------------------------
  -- New rules appended to the original four:
  --   suspicious_dx         in_list on dx_code
  --   weekend_service_date  is_weekend() on actual service_date field
  --   invalid_npi_prefix    starts_with(provider.npi, "0")
  --   half_million_composite  composite [FLAG_FRAUD, RISK_SCORE 85]
  --   unapproved_state      NOT in_list(claim.state, approved)
  --   medium_value_range    LET binding, 25k < amount < 50k
  let extRulesText =
        claimRulesText
          <> " RULE suspicious_dx \"Flag diagnosis codes associated with fraud\" \
             \WHEN in_list(claim.dx_code, [\"Z76.89\", \"Z09\", \"Z00.00\", \"T78.40XA\"]) \
             \THEN FLAG_FRAUD \"Suspicious diagnosis code\"; \
             \RULE weekend_service_date \"Flag elevated weekend service claims\" \
             \WHEN is_weekend(claim.service_date) AND 2300.CLM.claim_amount > 1000 \
             \THEN REQUIRE_REVIEW \"Weekend service date with elevated amount\"; \
             \RULE invalid_npi_prefix \"NPI cannot start with zero\" \
             \WHEN starts_with(provider.npi, \"0\") \
             \THEN FLAG_FRAUD \"Invalid NPI: leading zero\"; \
             \RULE half_million_composite \"Composite flag for claims over $500k\" \
             \WHEN 2300.CLM.claim_amount > 500000 \
             \THEN [FLAG_FRAUD \"Half-million dollar claim\", RISK_SCORE 85]; \
             \RULE unapproved_state \"Provider state not in approved network\" \
             \WHEN NOT in_list(claim.state, [\"TX\", \"CA\", \"NY\", \"FL\", \"WA\"]) \
             \THEN REQUIRE_REVIEW \"Provider not in approved network states\"; \
             \RULE medium_value_range \"Medium-value range requiring review\" \
             \LET claim_amt = 2300.CLM.claim_amount \
             \WHEN claim_amt > 25000 AND claim_amt < 50000 \
             \THEN REQUIRE_REVIEW \"Medium-value claim 25k-50k\";"

  let Right extEngine = loadRules extRulesText

  -- Rich claim helper: includes claim.dx_code, claim.service_date, claim.state, provider.npi
  let mkRichClaim amount pos dowField serviceDate dx claimState npi facilityType =
        object
          [ "claim"
              .= object
                [ "dx_code" .= (dx :: String)
                , "service_date" .= (serviceDate :: String)
                , "state" .= (claimState :: String)
                ]
          , "2300"
              .= object
                [ "CLM"
                    .= object
                      [ "claim_amount" .= (amount :: Double)
                      , "facility_type" .= (facilityType :: String)
                      ]
                ]
          , "2400"
              .= object
                [ "SV1" .= object ["place_of_service" .= (pos :: String)]
                , "DTP" .= object ["service_day_of_week" .= (dowField :: String)]
                ]
          , "provider" .= object ["npi" .= (npi :: String)]
          ]

  describe "Extended Claim Scenarios — 6 New Rules" $ do
    --  CLM016 ─ suspicious diagnosis code
    it "CLM016 suspicious dx (Z76.89, $3k, Tue): FLAG_FRAUD → CriticalRisk" $ do
      let claim  = mkRichClaim 3000  "11" "TUE" "2026-02-24" "Z76.89" "TX" "1234567890" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      -- only suspicious_dx fires
      reportMatchedRules report `shouldBe` 1
      reportOverallRisk  report `shouldBe` CriticalRisk

    --  CLM017 ─ service_date is Saturday, but DTP day-of-week field says TUE (data inconsistency)
    --           weekend_service_date fires (uses actual date); weekend_office_visit does NOT
    it "CLM017 weekend service_date (2026-02-21 Sat, DOW field=TUE, $2500): weekend_service_date only" $ do
      let claim  = mkRichClaim 2500  "11" "TUE" "2026-02-21" "M54.5" "TX" "1234567890" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      reportMatchedRules report `shouldBe` 1
      let matched = filter resultMatched (reportResults report)
      map resultRuleName matched `shouldContain` ["weekend_service_date"]

    --  CLM018 ─ invalid NPI (starts with "0")
    it "CLM018 invalid NPI prefix (0123456789, $8k): FLAG_FRAUD → CriticalRisk" $ do
      let claim  = mkRichClaim 8000  "11" "TUE" "2026-02-24" "M54.5" "TX" "0123456789" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      reportMatchedRules report `shouldBe` 1
      reportOverallRisk  report `shouldBe` CriticalRisk

    --  CLM019 ─ $750k: half_million_composite [FLAG_FRAUD, RISK_SCORE 85] + high_value_review
    it "CLM019 half-million ($750k, Tue): composite FLAG_FRAUD + high_value_review → CriticalRisk" $ do
      let claim  = mkRichClaim 750000 "11" "TUE" "2026-02-24" "M54.5" "TX" "1234567890" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      reportMatchedRules report `shouldBe` 2
      reportOverallRisk  report `shouldBe` CriticalRisk

    --  CLM020 ─ provider in Montana (unapproved state)
    it "CLM020 unapproved state (MT, $4k, Tue): unapproved_state → REQUIRE_REVIEW" $ do
      let claim  = mkRichClaim 4000  "11" "TUE" "2026-02-24" "M54.5" "MT" "1234567890" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      reportMatchedRules report `shouldBe` 1
      -- REQUIRE_REVIEW asks for analyst review, so the claim is HighRisk
      reportOverallRisk  report `shouldBe` HighRisk

    --  CLM021 ─ $35k: medium_value_range fires via LET binding; high_value_review does NOT
    it "CLM021 medium value ($35k, Tue, LET binding): medium_value_range only" $ do
      let claim  = mkRichClaim 35000 "11" "TUE" "2026-02-24" "M54.5" "TX" "1234567890" "Outpatient"
          report = evaluateSimpleJson extEngine testDay claim
      -- 25000 < 35000 < 50000 → medium_value_range; high_value_review requires > 50000
      reportMatchedRules report `shouldBe` 1
      let matched = filter resultMatched (reportResults report)
      map resultRuleName matched `shouldContain` ["medium_value_range"]

  -- ----------------------------------------------------------------
  -- Redundancy Checker
  -- ----------------------------------------------------------------
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

  describe "BETWEEN operator" $ do
    it "parses BETWEEN with numeric values" $ do
      let input = "RULE test \"Test\" WHEN amount BETWEEN 100 AND 500 THEN RISK_SCORE 50;"
      parseRule input `shouldSatisfy` isRight

    it "BETWEEN evaluates inclusively (lower bound)" $ do
      let input = "RULE test \"Test\" WHEN amount BETWEEN 100 AND 500 THEN RISK_SCORE 50;"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["amount" .= (100 :: Int)]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "BETWEEN evaluates inclusively (upper bound)" $ do
      let input = "RULE test \"Test\" WHEN amount BETWEEN 100 AND 500 THEN RISK_SCORE 50;"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["amount" .= (500 :: Int)]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "BETWEEN rejects value below range" $ do
      let input = "RULE test \"Test\" WHEN amount BETWEEN 100 AND 500 THEN RISK_SCORE 50;"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["amount" .= (99 :: Int)]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "BETWEEN combined with outer AND does not conflict" $ do
      let input = "RULE test \"Test\" WHEN amount BETWEEN 100 AND 500 AND status = \"pending\" THEN RISK_SCORE 50;"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["amount" .= (200 :: Int), "status" .= ("pending" :: String)]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

  describe "claim.has_diagnosis and claim.has_procedure" $ do
    it "parses claim.has_diagnosis" $ do
      let input = "RULE dx \"Check dx\" WHEN claim.has_diagnosis \"E11.9\" THEN FLAG_FRAUD \"diabetes\";"
      parseRule input `shouldSatisfy` isRight

    it "has_diagnosis finds code in diagnosis_codes array" $ do
      let input = "RULE dx \"Check dx\" WHEN claim.has_diagnosis \"E11.9\" THEN FLAG_FRAUD \"diabetes\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["diagnosis_codes" .= [object ["code" .= ("E11.9" :: String), "qualifier" .= ("Principal" :: String)]]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "has_diagnosis returns false when code absent" $ do
      let input = "RULE dx \"Check dx\" WHEN claim.has_diagnosis \"E11.9\" THEN FLAG_FRAUD \"diabetes\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["diagnosis_codes" .= [object ["code" .= ("Z00.00" :: String)]]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "parses claim.has_procedure" $ do
      let input = "RULE px \"Check px\" WHEN claim.has_procedure \"99213\" THEN REQUIRE_REVIEW \"office visit\";"
      parseRule input `shouldSatisfy` isRight

    it "has_procedure finds code in service_lines" $ do
      let input = "RULE px \"Check px\" WHEN claim.has_procedure \"99213\" THEN REQUIRE_REVIEW \"office visit\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["service_lines" .= [object ["procedure_code" .= ("99213" :: String)]]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "has_procedure checks procedure_codes array" $ do
      let input = "RULE px \"Check px\" WHEN claim.has_procedure \"80053\" THEN REQUIRE_REVIEW \"lab\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["procedure_codes" .= [object ["code" .= ("80053" :: String)]]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

  describe "APPROVE action" $ do
    it "parses APPROVE action" $ do
      let input = "RULE clean \"Auto-approve\" WHEN amount < 1000 THEN APPROVE \"Low-value auto-approve\";"
      parseRule input `shouldSatisfy` isRight

    it "APPROVE does not elevate risk level" $ do
      let input = "RULE clean \"Auto-approve\" WHEN TRUE THEN APPROVE \"auto\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["amount" .= (100 :: Int)]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True
          resultAction result `shouldBe` Just (ApproveClaim "auto")

    it "APPROVE does not override REJECT from other rules" $ do
      let rulesText = "RULE approve_rule \"Auto\" WHEN TRUE THEN APPROVE \"ok\"; \
                       \RULE reject_rule \"Bad\" WHEN TRUE THEN REJECT \"fail\";"
      case loadRules rulesText of
        Left err -> expectationFailure $ "Parse failed: " ++ err
        Right engine -> do
          let doc = object []
              report = evaluateSimpleJson engine testDay doc
          reportOverallRisk report `shouldBe` CriticalRisk

    it "APPROVE-only rules do not create DSL concern in PolicyCombiner" $ do
      let rules = [mkResult "approve_rule" True (Just (ApproveClaim "ok")) "approved"]
          ml = mlStubResult {mlRiskScore = Just 0.10}
          out = buildCombinedEnvelope defaultPolicyConfig "claim_approve" "2026-02-27T00:00:00Z" rules ml
      status (decision out) `shouldBe` "APPROVE"
      queue (decision out) `shouldBe` "none"

  describe "Nested quantifier variables (IN clause)" $ do
    it "parses EXISTS with named variable" $ do
      let input = "RULE test \"Test\" WHEN EXISTS line IN service_lines WHERE line.procedure_code = \"99213\" THEN FLAG_FRAUD \"found\";"
      parseRule input `shouldSatisfy` isRight

    it "parses FORALL with named variable" $ do
      let input = "RULE test \"Test\" WHEN FORALL line IN service_lines WHERE line.amount > 0 THEN RISK_SCORE 10;"
      parseRule input `shouldSatisfy` isRight

    it "old-style EXISTS still works (backward compat)" $ do
      let input = "RULE test \"Test\" WHEN EXISTS service_lines WHERE procedure_code = \"99213\" THEN FLAG_FRAUD \"found\";"
      parseRule input `shouldSatisfy` isRight

    it "named EXISTS evaluates correctly" $ do
      let input = "RULE test \"Test\" WHEN EXISTS line IN service_lines WHERE line.procedure_code = \"99213\" THEN FLAG_FRAUD \"found\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "service_lines" .= [ object ["procedure_code" .= ("99213" :: String), "amount" .= (150 :: Int)]
                                      , object ["procedure_code" .= ("80053" :: String), "amount" .= (85 :: Int)]
                                      ]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "EXISTS resolves every component of a nested collection path" $ do
      let input = "RULE test \"Test\" WHEN EXISTS dx IN claim.diagnosis_codes WHERE dx.code = \"E11.9\" THEN FLAG_FRAUD \"found\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "claim" .= object
                    [ "diagnosis_codes" .=
                        [ object ["code" .= ("E11.9" :: String)]
                        , object ["code" .= ("I10" :: String)]
                        ]
                    ]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "COUNT resolves every component of a nested collection path" $ do
      let input = "RULE test \"Test\" WHEN COUNT(claim.diagnosis_codes) = 2 THEN FLAG_FRAUD \"count\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "claim" .= object
                    [ "diagnosis_codes" .=
                        [ object ["code" .= ("E11.9" :: String)]
                        , object ["code" .= ("I10" :: String)]
                        ]
                    ]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "COUNT of an empty nested collection is zero" $ do
      let input = "RULE test \"Test\" WHEN COUNT(2400.SV1) = 0 THEN FLAG_FRAUD \"empty\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "2400" .= object ["SV1" .= ([] :: [Aeson.Value])]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "named FORALL evaluates correctly" $ do
      let input = "RULE test \"Test\" WHEN FORALL line IN service_lines WHERE line.amount > 0 THEN RISK_SCORE 10;"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "service_lines" .= [ object ["amount" .= (150 :: Int)]
                                      , object ["amount" .= (85 :: Int)]
                                      ]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "named EXISTS can access parent doc fields alongside bound variable" $ do
      let input = "RULE test \"Test\" WHEN EXISTS line IN service_lines WHERE line.amount > 100 AND claim_type = \"emergency\" THEN FLAG_FRAUD \"found\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object
                [ "claim_type" .= ("emergency" :: String)
                , "service_lines" .= [ object ["amount" .= (150 :: Int)] ]
                ]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

  -- ----------------------------------------------------------------
  -- New Helper Functions — Date, NPI, Age
  -- ----------------------------------------------------------------

  describe "New helper functions" $ do
    it "is_future_date: detects a date after today" $ do
      let input = "RULE future \"Future date\" WHEN is_future_date(claim.service_date) THEN REJECT \"future date\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2027-06-15" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "is_future_date: past date does not match" $ do
      let input = "RULE future \"Future date\" WHEN is_future_date(claim.service_date) THEN REJECT \"future date\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2025-01-15" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_date_before: detects a date before cutoff" $ do
      let input = "RULE old \"Old date\" WHEN is_date_before(claim.service_date, \"1900-01-01\") THEN REJECT \"too old\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("1899-12-31" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "is_date_before: date after cutoff does not match" $ do
      let input = "RULE old \"Old date\" WHEN is_date_before(claim.service_date, \"1900-01-01\") THEN REJECT \"too old\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2020-06-15" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_valid_npi: accepts valid NPI with correct Luhn checksum" $ do
      -- 1234567893 is a valid NPI (Luhn-10 with 80840 prefix)
      let input = "RULE npi \"NPI check\" WHEN is_valid_npi(provider.npi) THEN APPROVE \"valid\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["provider" .= object ["npi" .= ("1234567893" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "is_valid_npi: rejects NPI with wrong check digit" $ do
      let input = "RULE npi \"NPI check\" WHEN is_valid_npi(provider.npi) THEN APPROVE \"valid\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["provider" .= object ["npi" .= ("1234567890" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_npi_format: accepts 10-digit string" $ do
      let input = "RULE fmt \"NPI format\" WHEN is_npi_format(provider.npi) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["provider" .= object ["npi" .= ("0000000000" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "is_npi_format: rejects non-10-digit string" $ do
      let input = "RULE fmt \"NPI format\" WHEN is_npi_format(provider.npi) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["provider" .= object ["npi" .= ("12345" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_npi_format: rejects string with letters" $ do
      let input = "RULE fmt \"NPI format\" WHEN is_npi_format(provider.npi) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["provider" .= object ["npi" .= ("123456789a" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_age_valid: accepts age within range" $ do
      -- testDay is 2026-02-28; DOB 1990-05-15 → age 35
      let input = "RULE age \"Age check\" WHEN is_age_valid(patient.dob, 0, 130) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["patient" .= object ["dob" .= ("1990-05-15" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` True

    it "is_age_valid: rejects negative age (future DOB)" $ do
      let input = "RULE age \"Age check\" WHEN is_age_valid(patient.dob, 0, 130) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["patient" .= object ["dob" .= ("2030-01-01" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

    it "is_age_valid: rejects age over 130" $ do
      let input = "RULE age \"Age check\" WHEN is_age_valid(patient.dob, 0, 130) THEN APPROVE \"ok\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["patient" .= object ["dob" .= ("1880-01-01" :: String)]]
          resultMatched (evaluateRuleSimple testDay doc rule) `shouldBe` False

  -- ----------------------------------------------------------------
  -- Numeric equality, number formatting, helper scope
  -- ----------------------------------------------------------------

  describe "Numeric values and helper scope" $ do
    let matches input doc = case parseRule input of
          Left err -> expectationFailure ("Parse failed: " ++ show err) >> pure False
          Right rule -> pure (resultMatched (evaluateRuleSimple testDay doc rule))
        amountDoc = object ["amount" .= (100 :: Int)]

    it "= matches a JSON integer against a number literal" $
      matches "RULE t \"T\" WHEN amount = 100 THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` True

    it "= matches a JSON decimal against a number literal" $
      matches "RULE t \"T\" WHEN amount = 99.5 THEN FLAG_FRAUD \"x\";" (object ["amount" .= (99.5 :: Double)]) `shouldReturn` True

    it "= does not match a different number" $
      matches "RULE t \"T\" WHEN amount = 101 THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` False

    it "!= matches a different number" $
      matches "RULE t \"T\" WHEN amount != 5 THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` True

    it "!= does not match an equal number" $
      matches "RULE t \"T\" WHEN amount != 100 THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` False

    it "= against a number literal does not match a missing field" $
      matches "RULE t \"T\" WHEN other = 100 THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` False

    it "a JSON integer compares equal to the same digits as a string" $
      matches "RULE t \"T\" WHEN amount = \"100\" THEN FLAG_FRAUD \"x\";" amountDoc `shouldReturn` True

    it "a numeric NPI keeps its digits for is_npi_format" $
      matches "RULE t \"T\" WHEN is_npi_format(npi) THEN FLAG_FRAUD \"x\";" (object ["npi" .= (1234567893 :: Int)]) `shouldReturn` True

    it "a numeric NPI passes is_valid_npi" $
      matches "RULE t \"T\" WHEN is_valid_npi(npi) THEN FLAG_FRAUD \"x\";" (object ["npi" .= (1234567893 :: Int)]) `shouldReturn` True

    it "in_list matches a numeric field against number literals" $
      matches "RULE t \"T\" WHEN in_list(code, [99213, 99214]) THEN FLAG_FRAUD \"x\";" (object ["code" .= (99213 :: Int)]) `shouldReturn` True

    it "helpers can read a named EXISTS variable" $
      matches
        "RULE t \"T\" WHEN EXISTS l IN service_lines WHERE is_weekend(l.date) THEN FLAG_FRAUD \"x\";"
        (object ["service_lines" .= [object ["date" .= ("2026-02-27" :: String)], object ["date" .= ("2026-02-28" :: String)]]])
        `shouldReturn` True

    it "helpers can read a named FORALL variable" $
      matches
        "RULE t \"T\" WHEN FORALL l IN service_lines WHERE is_high_amount(l.amount, 500) THEN FLAG_FRAUD \"x\";"
        (object ["service_lines" .= [object ["amount" .= (600 :: Int)], object ["amount" .= (900 :: Int)]]])
        `shouldReturn` True

    it "reportMatchedRules forces every rule's predicate (the server's timeout relies on this)" $ do
      case loadRules "RULE t \"T\" WHEN amount > 1 THEN FLAG_FRAUD \"x\";" of
        Left err -> expectationFailure err
        Right engine ->
          evaluate (reportMatchedRules (evaluateSimpleJson engine testDay (error "document was read")))
            `shouldThrow` errorCall "document was read"

  -- ----------------------------------------------------------------
  -- Helper-name validation and deep field paths
  -- ----------------------------------------------------------------

  describe "Helper validation" $ do
    let parseError input = either show (const "") (parseRule input)

    it "rejects an unknown helper name" $
      parseError "RULE t \"T\" WHEN is_weekand(code) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "Unknown helper function: is_weekand"

    it "rejects a known helper called with too few arguments" $
      parseError "RULE t \"T\" WHEN is_date_before(dos) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "is_date_before takes 2 arguments, got 1"

    it "rejects a known helper called with too many arguments" $
      parseError "RULE t \"T\" WHEN is_weekend(dos, other) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "is_weekend takes 1 argument, got 2"

    it "accepts helper names in any letter case, as the evaluator does" $
      parseRule "RULE t \"T\" WHEN IS_WEEKEND(dos) THEN FLAG_FRAUD \"x\";" `shouldSatisfy` isRight

    it "accepts every documented helper with its argument count" $
      mapM_
        (\call -> (call, parseRule ("RULE t \"T\" WHEN " <> call <> " THEN FLAG_FRAUD \"x\";")) `shouldSatisfy` (isRight . snd))
        [ "is_weekend(dos)"
        , "is_high_amount(amount, 500)"
        , "starts_with(code, \"99\")"
        , "in_list(code, [\"A\", \"B\"])"
        , "is_future_date(dos)"
        , "is_date_before(dos, \"1900-01-01\")"
        , "is_valid_npi(npi)"
        , "is_npi_format(npi)"
        , "is_age_valid(dob, 0, 130)"
        ]

  describe "Field paths longer than three parts" $ do
    let deepDoc = object
          [ "claim" .= object
              [ "billing_provider" .= object
                  [ "address" .= object ["zip" .= ("02139" :: String)] ]
              ]
          , "service_lines" .=
              [ object ["provider" .= object ["address" .= object ["state" .= ("MA" :: String)]]] ]
          ]
        matches input = case parseRule input of
          Left err -> expectationFailure ("Parse failed: " ++ show err) >> pure False
          Right rule -> pure (resultMatched (evaluateRuleSimple testDay deepDoc rule))

    it "compares a four-part field" $
      matches "RULE t \"T\" WHEN claim.billing_provider.address.zip = \"02139\" THEN FLAG_FRAUD \"x\";"
        `shouldReturn` True

    it "does not match a four-part field with a different value" $
      matches "RULE t \"T\" WHEN claim.billing_provider.address.zip = \"10001\" THEN FLAG_FRAUD \"x\";"
        `shouldReturn` False

    it "treats a missing four-part field as NULL" $
      matches "RULE t \"T\" WHEN claim.billing_provider.address.city IS NULL THEN FLAG_FRAUD \"x\";"
        `shouldReturn` True

    it "binds a four-part field with LET" $
      matches "RULE t \"T\" LET z = claim.billing_provider.address.zip WHEN z = \"02139\" THEN FLAG_FRAUD \"x\";"
        `shouldReturn` True

    it "reads a deep path under a quantifier variable" $
      matches "RULE t \"T\" WHEN EXISTS l IN service_lines WHERE l.provider.address.state = \"MA\" THEN FLAG_FRAUD \"x\";"
        `shouldReturn` True

    it "compares a deep field against another field" $
      matches "RULE t \"T\" WHEN claim.billing_provider.address.zip = claim.billing_provider.address.zip THEN FLAG_FRAUD \"x\";"
        `shouldReturn` True

    it "treats alpha-equivalent quantifiers over deep paths as redundant" $ do
      let parsed = mapM parseRule
            [ "RULE a \"A\" WHEN EXISTS l IN service_lines WHERE l.provider.address.state = \"MA\" THEN FLAG_FRAUD \"x\";"
            , "RULE b \"B\" WHEN EXISTS s IN service_lines WHERE s.provider.address.state = \"MA\" THEN FLAG_FRAUD \"x\";"
            ]
      case parsed of
        Right [a, b] -> checkRedundancy a [b] `shouldSatisfy` (not . null)
        other -> expectationFailure ("Parse failed: " ++ show other)

  -- ----------------------------------------------------------------
  -- Missing data is unknown: it never makes a rule match by itself
  -- ----------------------------------------------------------------

  describe "Overall risk level" $ do
    let riskOf rulesText = case loadRules rulesText of
          Left err -> error err
          Right engine -> reportOverallRisk (evaluateSimpleJson engine testDay (object ["amount" .= (20000 :: Int)]))

    it "no matched rule is LowRisk" $
      riskOf "RULE a \"d\" WHEN amount > 50000 THEN FLAG_FRAUD \"x\";" `shouldBe` LowRisk

    it "a matched REQUIRE_REVIEW is HighRisk" $
      riskOf "RULE a \"d\" WHEN amount > 100 THEN REQUIRE_REVIEW \"check\";" `shouldBe` HighRisk

    it "a single matched RISK_SCORE of 70 or more is HighRisk" $ do
      riskOf "RULE a \"d\" WHEN amount > 100 THEN RISK_SCORE 70;" `shouldBe` HighRisk
      riskOf "RULE a \"d\" WHEN amount > 100 THEN RISK_SCORE 100;" `shouldBe` HighRisk

    it "a matched RISK_SCORE below 70 is LowRisk" $
      riskOf "RULE a \"d\" WHEN amount > 100 THEN RISK_SCORE 69;" `shouldBe` LowRisk

    it "REQUIRE_REVIEW inside a composite action is HighRisk" $
      riskOf "RULE a \"d\" WHEN amount > 100 THEN [RISK_SCORE 10, REQUIRE_REVIEW \"x\"];" `shouldBe` HighRisk

    it "FLAG_FRAUD or REJECT outranks review" $ do
      riskOf "RULE a \"d\" WHEN amount > 100 THEN [REQUIRE_REVIEW \"x\", FLAG_FRAUD \"y\"];" `shouldBe` CriticalRisk
      riskOf "RULE a \"d\" WHEN amount > 100 THEN REQUIRE_REVIEW \"x\"; \
             \RULE b \"d\" WHEN amount > 100 THEN REJECT \"y\";" `shouldBe` CriticalRisk

    it "APPROVE alone is LowRisk" $
      riskOf "RULE a \"d\" WHEN amount > 100 THEN APPROVE \"ok\";" `shouldBe` LowRisk

    it "a REQUIRE_REVIEW rule that did not match is ignored" $
      riskOf "RULE a \"d\" WHEN missing_field > 100 THEN REQUIRE_REVIEW \"x\";" `shouldBe` LowRisk

  describe "Missing data (three-valued logic)" $ do
    let doc = object
          [ "amount" .= (500 :: Int)
          , "npi" .= ("12345" :: String)
          , "dos" .= ("not a date" :: String)
          , "status" .= ("pending" :: String)
          , "diagnosis_codes" .= [object ["code" .= ("I10" :: String)]]
          , "empty_lines" .= ([] :: [Aeson.Value])
          , "lines" .=
              [ object ["amount" .= (10 :: Int), "code" .= ("A" :: String)]
              , object ["code" .= ("B" :: String)]
              ]
          , "bad_lines" .=
              [ object ["amount" .= (10 :: Int)]
              , object ["amount" .= (-5 :: Int)]
              ]
          ]
        run cond = case parseRule ("RULE t \"T\" WHEN " <> cond <> " THEN FLAG_FRAUD \"x\";") of
          Left err -> error ("Parse failed: " ++ show err)
          Right rule -> evaluateRuleSimple testDay doc rule
        matches cond = resultMatched (run cond)

    describe "NOT" $ do
      it "NOT of a comparison on a missing field does not match" $
        matches "NOT missing > 5" `shouldBe` False
      it "NOT of a comparison on a present field still matches" $
        matches "NOT amount > 10000" `shouldBe` True
      it "NOT of MATCHES on a missing field does not match" $
        matches "NOT (missing MATCHES \"^[0-9]{10}$\")" `shouldBe` False
      it "NOT of MATCHES on a present, failing field matches" $
        matches "NOT (npi MATCHES \"^[0-9]{10}$\")" `shouldBe` True
      it "an explicit IS NULL guard catches the missing field" $
        matches "missing IS NULL OR NOT (missing MATCHES \"^[0-9]{10}$\")" `shouldBe` True
      it "NOT of a helper on a missing field does not match" $
        matches "NOT is_weekend(missing)" `shouldBe` False
      it "NOT of a helper on an unreadable date does not match" $
        matches "NOT is_weekend(dos)" `shouldBe` False
      it "NOT of a numeric comparison on non-numeric text does not match" $
        matches "NOT status > 5" `shouldBe` False
      it "NOT has_diagnosis matches when the claim has other codes" $
        matches "NOT claim.has_diagnosis \"E11.9\"" `shouldBe` True
      it "NOT has_diagnosis does not match a claim with no diagnosis codes" $
        case parseRule "RULE t \"T\" WHEN NOT claim.has_diagnosis \"E11.9\" THEN FLAG_FRAUD \"x\";" of
          Left err -> expectationFailure (show err)
          Right rule -> resultMatched (evaluateRuleSimple testDay (object ["amount" .= (1 :: Int)]) rule) `shouldBe` False

    describe "AND / OR" $ do
      it "unknown OR true matches" $
        matches "missing > 5 OR amount = 500" `shouldBe` True
      it "unknown OR false does not match" $
        matches "missing > 5 OR amount = 1" `shouldBe` False
      it "NOT (unknown AND false) matches, because the AND is definitely false" $
        matches "NOT (missing > 5 AND amount = 1)" `shouldBe` True
      it "NOT (unknown AND true) does not match" $
        matches "NOT (missing > 5 AND amount = 500)" `shouldBe` False

    describe "Quantifiers" $ do
      it "FORALL over a missing collection does not match" $
        matches "FORALL l IN no_lines WHERE l.amount > 0" `shouldBe` False
      it "FORALL over an empty collection does not match" $
        matches "FORALL l IN empty_lines WHERE l.amount > 0" `shouldBe` False
      it "NOT FORALL over an empty collection does not match" $
        matches "NOT FORALL l IN empty_lines WHERE l.amount > 0" `shouldBe` False
      it "FORALL does not match when a line lacks the field" $
        matches "FORALL l IN lines WHERE l.amount > 0" `shouldBe` False
      it "NOT FORALL does not match when the only doubt is a missing field" $
        matches "NOT FORALL l IN lines WHERE l.amount > 0" `shouldBe` False
      it "NOT FORALL matches when a line definitely fails" $
        matches "NOT FORALL l IN bad_lines WHERE l.amount > 0" `shouldBe` True
      it "EXISTS over an empty collection does not match" $
        matches "EXISTS l IN empty_lines WHERE l.amount > 0" `shouldBe` False
      it "NOT EXISTS over an empty collection does not match" $
        matches "NOT EXISTS l IN empty_lines WHERE l.amount > 0" `shouldBe` False
      it "NOT EXISTS over a missing collection does not match" $
        matches "NOT EXISTS l IN no_lines WHERE l.amount > 0" `shouldBe` False
      it "NOT EXISTS matches when every line definitely fails" $
        matches "NOT EXISTS l IN bad_lines WHERE l.amount > 100" `shouldBe` True
      it "EXISTS matches when one line passes even if another is unknown" $
        matches "EXISTS l IN lines WHERE l.amount > 0" `shouldBe` True
      it "COUNT(...) = 0 is the explicit check for a missing collection" $
        matches "COUNT(no_lines) = 0" `shouldBe` True

    describe "Result details" $ do
      it "say when a rule was undecided because of missing data, naming the field" $
        resultDetails (run "NOT missing > 5") `shouldBe` "Rule did not match: missing or unusable data (missing missing)"
      it "name every missing field when both sides of an AND are unknown" $
        resultDetails (run "claim.amount > 5 AND provider.npi = \"1\"")
          `shouldBe` "Rule did not match: missing or unusable data (claim.amount missing; provider.npi missing)"
      it "name only the unknown side when the other side is true" $
        resultDetails (run "amount = 500 AND provider.npi = \"1\"")
          `shouldBe` "Rule did not match: missing or unusable data (provider.npi missing)"
      it "name a field that is present but not a number" $
        resultDetails (run "status > 5") `shouldBe` "Rule did not match: missing or unusable data (status is not a number)"
      it "name a helper argument that is not a valid date" $
        resultDetails (run "is_future_date(dos)") `shouldBe` "Rule did not match: missing or unusable data (dos is not a valid date)"
      it "name an empty collection" $
        resultDetails (run "EXISTS l IN empty_lines WHERE l.amount > 0")
          `shouldBe` "Rule did not match: missing or unusable data (empty_lines missing or empty)"
      it "name a field inside a collection by the collection's name, once" $
        resultDetails (run "FORALL l IN lines WHERE l.amount > 0")
          `shouldBe` "Rule did not match: missing or unusable data (lines[].amount missing)"
      it "name a field inside an anonymous quantifier by the collection's name" $
        resultDetails (run "FORALL lines WHERE amount > 0")
          `shouldBe` "Rule did not match: missing or unusable data (lines[].amount missing)"
      it "name missing diagnosis codes" $
        case parseRule "RULE t \"T\" WHEN claim.has_diagnosis \"E11.9\" THEN FLAG_FRAUD \"x\";" of
          Left err -> expectationFailure (show err)
          Right rule ->
            resultDetails (evaluateRuleSimple testDay (object ["amount" .= (1 :: Int)]) rule)
              `shouldBe` "Rule did not match: missing or unusable data (diagnosis_codes missing or empty)"
      it "keep the plain wording when the rule was definitely false" $
        resultDetails (run "amount > 10000") `shouldBe` "Rule did not match"

    describe "Undecided flag" $ do
      it "is set when a rule depends on missing data" $
        resultUndecided (run "missing > 5") `shouldBe` True
      it "is set when a rule depends on unusable data" $
        resultUndecided (run "is_future_date(dos)") `shouldBe` True
      it "is not set when a rule is definitely false" $
        resultUndecided (run "amount > 10000") `shouldBe` False
      it "is not set when a rule matches" $
        resultUndecided (run "amount > 100") `shouldBe` False
      it "is set when a LET binding cannot be resolved" $
        case parseRule "RULE t \"T\" LET x = missing WHEN x = \"y\" THEN FLAG_FRAUD \"x\";" of
          Left err -> expectationFailure ("Parse failed: " ++ show err)
          Right rule -> resultUndecided (evaluateRuleSimple testDay doc rule) `shouldBe` True
      it "is counted in the report" $
        case loadRules "RULE a \"A\" WHEN missing > 5 THEN FLAG_FRAUD \"x\"; \
                       \RULE b \"B\" WHEN amount > 10000 THEN FLAG_FRAUD \"x\"; \
                       \RULE c \"C\" WHEN amount > 100 THEN REQUIRE_REVIEW \"x\";" of
          Left err -> expectationFailure ("Parse failed: " ++ err)
          Right engine -> do
            let report = evaluateSimpleJson engine testDay doc
            reportMatchedRules report `shouldBe` 1
            reportUndecidedRules report `shouldBe` 1
            reportSummary report
              `shouldBe` "Evaluated 3 rules, 1 matched, 1 not checked (missing data). Overall risk: HighRisk"

  -- ----------------------------------------------------------------
  -- Default Rule DSL Texts — Parse Validation
  -- ----------------------------------------------------------------

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

mkResult :: String -> Bool -> Maybe Action -> String -> RuleResult
mkResult name matched action details =
  RuleResult
    { resultRuleName = fromString name,
      resultMatched = matched,
      resultAction = action,
      resultDetails = fromString details,
      resultUndecided = False
    }
