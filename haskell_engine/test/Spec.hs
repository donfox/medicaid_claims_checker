{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.String (fromString)
import Data.Time (Day, fromGregorian)
import Test.Hspec
import BusinessRulesSpec (businessRulesSpec)
import ParserProps (parserProperties)
import Claims.EvaluationContract
import Claims.MLClient
import Claims.Parser
import Claims.PolicyCombiner
import Claims.RuleEngine (EvaluationReport (..), RiskLevel (..), evaluateSimpleJson, loadRules)
import Claims.RedundancyChecker
import Claims.SimpleEvaluator (evaluateRuleSimple)
import Claims.Syntax

-- | Fixed test date: 2026-02-28 (Saturday)
testDay :: Day
testDay = fromGregorian 2026 2 28

main :: IO ()
main = hspec $ do
  businessRulesSpec
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
      -- REQUIRE_REVIEW action does not elevate RiskLevel; only FlagFraud/Reject/RISK_SCORE>=70 do
      reportOverallRisk report `shouldBe` LowRisk

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
      -- REQUIRE_REVIEW does not raise RiskLevel
      reportOverallRisk  report `shouldBe` LowRisk

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
      let ruleA = mkRule "rule_a" (GreaterThan (SegmentField "financial" "claim_amount") (NumberValue 50000)) (RequireReview "high value")
          ruleB = mkRule "rule_b" (GreaterThan (SegmentField "financial" "claim_amount") (NumberValue 50000)) (RequireReview "high value")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ExactDuplicate

    it "detects exact duplicate with commutative AND" $ do
      let condA = And (Equals (Field "state") (StringValue "CA")) (GreaterThan (Field "amount") (NumberValue 1000))
          condB = And (GreaterThan (Field "amount") (NumberValue 1000)) (Equals (Field "state") (StringValue "CA"))
          ruleA = mkRule "rule_a" condA (FlagFraud "test")
          ruleB = mkRule "rule_b" condB (FlagFraud "test")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ExactDuplicate

    it "detects condition overlap on same field with overlapping numeric ranges" $ do
      -- > 40000 vs < 60000: ranges overlap but neither implies the other
      let ruleA = mkRule "rule_a" (GreaterThan (Field "amount") (NumberValue 40000)) (RequireReview "review 40k")
          ruleB = mkRule "rule_b" (LessThan (Field "amount") (NumberValue 60000)) (FlagFraud "low amount")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` ConditionOverlap

    it "detects shadowed: broader rule subsumes narrower with different action" $ do
      let ruleA = mkRule "broad" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "high")
          ruleB = mkRule "narrow" (And (GreaterThan (Field "amount") (NumberValue 50000)) (Equals (Field "state") (StringValue "CA"))) (FlagFraud "ca high")
          matches = checkRedundancy ruleB [ruleA]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Shadowed

    it "detects subsumption with same action (truly redundant)" $ do
      let ruleA = mkRule "broad" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "high")
          ruleB = mkRule "narrow" (And (GreaterThan (Field "amount") (NumberValue 50000)) (Equals (Field "state") (StringValue "CA"))) (RequireReview "high")
          matches = checkRedundancy ruleB [ruleA]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Subsumption

    it "no match for completely different fields" $ do
      let ruleA = mkRule "rule_a" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "amount")
          ruleB = mkRule "rule_b" (Equals (Field "state") (StringValue "CA")) (RequireReview "state")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "detects shadowed with numeric tightening (> 60000 implies > 50000, different text)" $ do
      let ruleA = mkRule "stricter" (GreaterThan (Field "amount") (NumberValue 60000)) (RequireReview "60k")
          ruleB = mkRule "looser" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "50k")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 1
      matchLevel (head matches) `shouldBe` Shadowed

    it "NOT does not produce false overlap" $ do
      let ruleA = mkRule "rule_a" (Not (GreaterThan (Field "amount") (NumberValue 50000))) (RequireReview "low")
          ruleB = mkRule "rule_b" (GreaterThan (Field "amount") (NumberValue 40000)) (FlagFraud "high")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "!= does not produce false overlap" $ do
      let ruleA = mkRule "rule_a" (NotEquals (Field "status") (StringValue "approved")) (RequireReview "not approved")
          ruleB = mkRule "rule_b" (GreaterThan (Field "status") (NumberValue 0)) (FlagFraud "positive")
          matches = checkRedundancy ruleA [ruleB]
      length matches `shouldBe` 0

    it "returns most specific level only (exact dup wins over overlap)" $ do
      let ruleA = mkRule "rule_a" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "same")
          ruleB = mkRule "rule_b" (GreaterThan (Field "amount") (NumberValue 50000)) (RequireReview "same")
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
          resultAction result `shouldBe` Just (ApproveClaim' "auto")

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
      let rules = [mkResult "approve_rule" True (Just (ApproveClaim' "ok")) "approved"]
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
  -- Default Rule DSL Texts — Parse Validation
  -- ----------------------------------------------------------------

  describe "Default Rule DSL texts parse correctly" $ do
    let defaultRuleDsls =
          [ ("ImpossibleDates",
             "RULE impossible_dates \"test\" WHEN is_future_date(service_lines.0.date_of_service) OR is_date_before(service_lines.0.date_of_service, \"1900-01-01\") THEN REJECT \"bad\";")
          , ("ExtremeAmounts",
             "RULE extreme_amounts \"test\" WHEN claim_totals.total_charges > 1000000 THEN FLAG_FRAUD \"extreme\";")
          , ("MissingRequiredFields",
             "RULE missing_required_fields \"test\" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT \"missing\";")
          , ("InvalidProviderNPI",
             "RULE invalid_provider_npi \"test\" WHEN provider.npi IS NOT NULL AND NOT is_valid_npi(provider.npi) THEN REJECT \"invalid npi\";")
          , ("FutureServiceDate",
             "RULE future_service_date \"test\" WHEN is_future_date(service_lines.0.date_of_service) THEN REJECT \"future\";")
          , ("InvalidNPIFormat",
             "RULE invalid_npi_format \"test\" WHEN provider.npi IS NOT NULL AND NOT is_npi_format(provider.npi) THEN REJECT \"format\";")
          , ("MissingDiagnosisCodes",
             "RULE missing_diagnosis_codes \"test\" WHEN COUNT(diagnosis_codes) = 0 THEN REJECT \"no dx\";")
          , ("ExcessiveTotalCharges",
             "RULE excessive_total_charges \"test\" WHEN claim_totals.total_charges > 750000 THEN FLAG_FRAUD \"excessive\";")
          , ("PatientAgeOutOfRange",
             "RULE patient_age_out_of_range \"test\" WHEN patient.date_of_birth IS NOT NULL AND NOT is_age_valid(patient.date_of_birth, 0, 130) THEN REJECT \"age\";")
          ]

    mapM_ (\(label, dsl) ->
      it (label ++ " DSL parses") $ parseRule dsl `shouldSatisfy` isRight
      ) defaultRuleDsls

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
