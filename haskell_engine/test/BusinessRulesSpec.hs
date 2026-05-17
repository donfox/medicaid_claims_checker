{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : BusinessRulesSpec
-- Description : HSpec tests for all 16 active business rules using business-schema JSON
--
-- Tests every active default rule by parsing the canonical DSL text and evaluating
-- it against hand-crafted business-schema JSON documents (not X12 segment paths).
module BusinessRulesSpec (businessRulesSpec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time (Day, fromGregorian)
import Test.Hspec
import Claims.Parser (parseRule)
import Claims.SimpleEvaluator (evaluateRuleSimple)
import Claims.Syntax (RuleResult (..))

-- ---------------------------------------------------------------------------
-- Fixed test date (same as Spec.hs)
-- ---------------------------------------------------------------------------

testDay :: Day
testDay = fromGregorian 2026 2 28

-- ---------------------------------------------------------------------------
-- Canonical DSL texts for all 16 active business rules
-- ---------------------------------------------------------------------------

ruleExcessiveTotalCharges :: String
ruleExcessiveTotalCharges =
  "RULE excessive_total_charges \"Flags claims with total charges exceeding $750,000 as potential fraud\" \
  \WHEN claim_totals.total_charges > 750000 \
  \THEN FLAG_FRAUD \"Total charges exceed $750K threshold\";"

ruleExtremeAmounts :: String
ruleExtremeAmounts =
  "RULE extreme_amounts \"Flags claims with total charges exceeding $1,000,000\" \
  \WHEN claim_totals.total_charges > 1000000 \
  \THEN FLAG_FRAUD \"Extreme billing amount exceeds $1M\";"

ruleFutureServiceDate :: String
ruleFutureServiceDate =
  "RULE future_service_date \"Rejects claims where the date of service has not yet occurred\" \
  \WHEN is_future_date(service_lines.0.date_of_service) \
  \THEN REJECT \"Service date is in the future\";"

ruleHighComplexityERVisit :: String
ruleHighComplexityERVisit =
  "RULE high_complexity_er_visit \
  \DESCRIPTION \"High-complexity ER visit (99285) with elevated charges requires clinical review\" \
  \WHEN service_lines.0.procedure_code = \"99285\" AND financial.claim_amount > 10000 \
  \THEN REQUIRE_REVIEW \"High-complexity ER — clinical validation required\" END"

ruleHighValueClaim :: String
ruleHighValueClaim =
  "RULE high_value_claim \
  \DESCRIPTION \"Claims exceeding $50,000 require manual review before payment\" \
  \WHEN financial.claim_amount > 50000 \
  \THEN REQUIRE_REVIEW \"Claim exceeds high-value threshold — manual approval required\" END"

ruleImpossibleDates :: String
ruleImpossibleDates =
  "RULE impossible_dates \"Rejects claims with service dates in the future or before 1900\" \
  \WHEN is_future_date(service_lines.0.date_of_service) \
  \OR is_date_before(service_lines.0.date_of_service, \"1900-01-01\") \
  \THEN REJECT \"Impossible service date detected\";"

ruleInvalidNPIFormat :: String
ruleInvalidNPIFormat =
  "RULE invalid_npi_format \"Rejects claims where the billing provider NPI is not exactly 10 digits\" \
  \WHEN provider.npi IS NOT NULL AND NOT is_npi_format(provider.npi) \
  \THEN REJECT \"Provider NPI is not a valid 10-digit number\";"

ruleInvalidProviderNPI :: String
ruleInvalidProviderNPI =
  "RULE invalid_provider_npi \"Validates that the billing provider NPI passes Luhn-10 checksum\" \
  \WHEN provider.npi IS NOT NULL AND NOT is_valid_npi(provider.npi) \
  \THEN REJECT \"Provider NPI fails Luhn-10 validation\";"

ruleMissingDiagnosisCodes :: String
ruleMissingDiagnosisCodes =
  "RULE missing_diagnosis_codes \"Rejects claims that contain no diagnosis codes\" \
  \WHEN COUNT(diagnosis_codes) = 0 \
  \THEN REJECT \"No diagnosis codes present on claim\";"

ruleMissingProviderTaxonomy :: String
ruleMissingProviderTaxonomy =
  "RULE missing_provider_taxonomy \
  \DESCRIPTION \"Flag claims missing provider taxonomy code for specialty verification\" \
  \WHEN billing_provider.taxonomy IS NULL AND financial.claim_amount > 1000 \
  \THEN REQUIRE_REVIEW \"Provider taxonomy code missing — cannot validate specialty\" END"

ruleMissingRequiredFields :: String
ruleMissingRequiredFields =
  "RULE missing_required_fields \"Ensures all mandatory fields are present in the claim payload\" \
  \WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL \
  \THEN REJECT \"Missing required claim field\";"

ruleNewProviderLargeSubmission :: String
ruleNewProviderLargeSubmission =
  "RULE new_provider_large_submission \
  \DESCRIPTION \"Large claim from a provider credentialed less than 90 days ago\" \
  \WHEN provider.tenure_days < 90 AND financial.claim_amount > 10000 \
  \THEN REQUIRE_REVIEW \"Large submission from newly credentialed provider\" END"

rulePatientAgeOutOfRange :: String
rulePatientAgeOutOfRange =
  "RULE patient_age_out_of_range \"Rejects claims where the patient age is negative or exceeds 130 years\" \
  \WHEN patient.date_of_birth IS NOT NULL AND NOT is_age_valid(patient.date_of_birth, 0, 130) \
  \THEN REJECT \"Patient age is out of valid range (0-130)\";"

ruleSuspiciouslyLowCharge :: String
ruleSuspiciouslyLowCharge =
  "RULE suspicious_low_charge \
  \DESCRIPTION \"Charge below $5 may indicate billing manipulation or data error\" \
  \WHEN financial.claim_amount < 5 \
  \THEN FLAG_FRAUD \"Suspiciously low charge — possible billing manipulation\" END"

ruleTaxonomyMismatchNewProvider :: String
ruleTaxonomyMismatchNewProvider =
  "RULE taxonomy_mismatch_new_provider \
  \DESCRIPTION \"New provider with missing taxonomy on high-value claim is high risk\" \
  \WHEN billing_provider.taxonomy IS NULL AND provider.tenure_days < 90 AND financial.claim_amount > 5000 \
  \THEN FLAG_FRAUD \"New provider with no taxonomy code submitting high-value claim\" END"

ruleUnauthorizedProcedure :: String
ruleUnauthorizedProcedure =
  "RULE unauthorized_procedure \
  \DESCRIPTION \"High-value claim submitted without a valid authorization number\" \
  \WHEN authorization.authorization_number IS NULL AND financial.claim_amount > 5000 \
  \THEN REJECT \"High-value claim lacks required authorization\" END"

-- ---------------------------------------------------------------------------
-- Helper: parse and evaluate a single rule
-- ---------------------------------------------------------------------------

evalRule :: String -> Aeson.Value -> IO RuleResult
evalRule ruleText doc = case parseRule (T.pack ruleText) of
  Left err -> expectationFailure ("Parse failed: " ++ show err) >> undefined
  Right rule -> pure $ evaluateRuleSimple testDay doc rule

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

businessRulesSpec :: Spec
businessRulesSpec =
  describe "Business Schema Rules" $ do

    -- -----------------------------------------------------------------------
    -- 1. Null-safety: numeric comparisons with null/missing fields return False
    -- -----------------------------------------------------------------------
    describe "Null-safety: numeric comparisons with null/missing fields return False" $ do

      it "tenure_days JSON null → NewProviderLargeSubmission does NOT fire even with $50K claim" $ do
        let doc = object
              [ "provider"  .= object ["tenure_days" .= Aeson.Null]
              , "financial" .= object ["claim_amount" .= (50000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` False

      it "tenure_days missing entirely → NewProviderLargeSubmission does NOT fire" $ do
        let doc = object
              [ "provider"  .= Aeson.object []
              , "financial" .= object ["claim_amount" .= (50000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` False

      it "financial.claim_amount null → HighValueClaim does NOT fire" $ do
        let doc = object
              [ "financial" .= object ["claim_amount" .= Aeson.Null]
              ]
        result <- evalRule ruleHighValueClaim doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 2. Null-safety: IS NULL correctly identifies null and missing fields
    -- -----------------------------------------------------------------------
    describe "Null-safety: IS NULL correctly identifies null and missing fields" $ do

      it "authorization.authorization_number JSON null → IS NULL returns True (rule fires with $10K)" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= Aeson.Null]
              , "financial"     .= object ["claim_amount" .= (10000 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` True

      it "authorization.authorization_number missing → IS NULL returns True (rule fires with $10K)" $ do
        let doc = object
              [ "authorization" .= Aeson.object []
              , "financial"     .= object ["claim_amount" .= (10000 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` True

      it "authorization.authorization_number present → IS NULL returns False (rule does NOT fire)" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= ("AUTH-001" :: String)]
              , "financial"     .= object ["claim_amount" .= (10000 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 3. MissingRequiredFields
    -- -----------------------------------------------------------------------
    describe "MissingRequiredFields fires when any mandatory field is absent" $ do

      it "claim_id null → fires" $ do
        let doc = object
              [ "claim_id"  .= Aeson.Null
              , "provider"  .= object ["npi" .= ("1003001850" :: String)]
              , "patient"   .= object ["date_of_birth" .= ("1990-01-15" :: String)]
              , "financial" .= object ["claim_amount" .= (1500 :: Double)]
              ]
        result <- evalRule ruleMissingRequiredFields doc
        resultMatched result `shouldBe` True

      it "provider.npi null → fires" $ do
        let doc = object
              [ "claim_id"  .= ("CLM-001" :: String)
              , "provider"  .= object ["npi" .= Aeson.Null]
              , "patient"   .= object ["date_of_birth" .= ("1990-01-15" :: String)]
              , "financial" .= object ["claim_amount" .= (1500 :: Double)]
              ]
        result <- evalRule ruleMissingRequiredFields doc
        resultMatched result `shouldBe` True

      it "patient.date_of_birth null → fires" $ do
        let doc = object
              [ "claim_id"  .= ("CLM-001" :: String)
              , "provider"  .= object ["npi" .= ("1003001850" :: String)]
              , "patient"   .= object ["date_of_birth" .= Aeson.Null]
              , "financial" .= object ["claim_amount" .= (1500 :: Double)]
              ]
        result <- evalRule ruleMissingRequiredFields doc
        resultMatched result `shouldBe` True

      it "financial.claim_amount null → fires" $ do
        let doc = object
              [ "claim_id"  .= ("CLM-001" :: String)
              , "provider"  .= object ["npi" .= ("1003001850" :: String)]
              , "patient"   .= object ["date_of_birth" .= ("1990-01-15" :: String)]
              , "financial" .= object ["claim_amount" .= Aeson.Null]
              ]
        result <- evalRule ruleMissingRequiredFields doc
        resultMatched result `shouldBe` True

      it "all required fields present → does NOT fire" $ do
        let doc = object
              [ "claim_id"  .= ("CLM-001" :: String)
              , "provider"  .= object ["npi" .= ("1003001850" :: String)]
              , "patient"   .= object ["date_of_birth" .= ("1990-01-15" :: String)]
              , "financial" .= object ["claim_amount" .= (1500 :: Double)]
              ]
        result <- evalRule ruleMissingRequiredFields doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 4. MissingDiagnosisCodes
    -- -----------------------------------------------------------------------
    describe "MissingDiagnosisCodes fires on empty array" $ do

      it "empty diagnosis_codes array [] → fires" $ do
        let doc = object ["diagnosis_codes" .= ([] :: [Aeson.Value])]
        result <- evalRule ruleMissingDiagnosisCodes doc
        resultMatched result `shouldBe` True

      it "one element diagnosis_codes array → does NOT fire" $ do
        let doc = object
              [ "diagnosis_codes" .= [object ["code" .= ("E11.9" :: String), "qualifier" .= ("Principal" :: String)]]
              ]
        result <- evalRule ruleMissingDiagnosisCodes doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 5. InvalidNPIFormat
    -- -----------------------------------------------------------------------
    describe "InvalidNPIFormat fires on non-10-digit NPI" $ do

      it "\"12345\" (5 digits) → fires" $ do
        let doc = object ["provider" .= object ["npi" .= ("12345" :: String)]]
        result <- evalRule ruleInvalidNPIFormat doc
        resultMatched result `shouldBe` True

      it "\"123456789a\" (letter in NPI) → fires" $ do
        let doc = object ["provider" .= object ["npi" .= ("123456789a" :: String)]]
        result <- evalRule ruleInvalidNPIFormat doc
        resultMatched result `shouldBe` True

      it "\"1003001850\" (valid 10-digit NPI) → does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003001850" :: String)]]
        result <- evalRule ruleInvalidNPIFormat doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 6. InvalidProviderNPI (Luhn-10)
    -- -----------------------------------------------------------------------
    describe "InvalidProviderNPI fires on bad Luhn checksum" $ do

      it "\"1234567890\" (bad Luhn) → fires" $ do
        let doc = object ["provider" .= object ["npi" .= ("1234567890" :: String)]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` True

      it "\"1003001850\" (valid Luhn — lab_work fixture NPI) → does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003001850" :: String)]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` False

      it "\"1003000118\" (valid Luhn — preventive fixture NPI) → does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003000118" :: String)]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` False

      it "null NPI → does NOT fire (IS NOT NULL guard)" $ do
        let doc = object ["provider" .= object ["npi" .= Aeson.Null]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 7. FutureServiceDate and ImpossibleDates
    -- -----------------------------------------------------------------------
    describe "FutureServiceDate and ImpossibleDates fire on bad service dates" $ do

      it "\"2099-01-01\" (future) → FutureServiceDate fires" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("2099-01-01" :: String), "procedure_code" .= ("80053" :: String)]]
              ]
        result <- evalRule ruleFutureServiceDate doc
        resultMatched result `shouldBe` True

      it "\"2020-01-01\" (past) → FutureServiceDate does NOT fire" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("2020-01-01" :: String), "procedure_code" .= ("80053" :: String)]]
              ]
        result <- evalRule ruleFutureServiceDate doc
        resultMatched result `shouldBe` False

      it "\"1899-12-31\" (before 1900) → ImpossibleDates fires" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("1899-12-31" :: String), "procedure_code" .= ("80053" :: String)]]
              ]
        result <- evalRule ruleImpossibleDates doc
        resultMatched result `shouldBe` True

      it "compact \"20990101\" → FutureServiceDate fires (parseDate handles both formats)" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("20990101" :: String), "procedure_code" .= ("80053" :: String)]]
              ]
        result <- evalRule ruleFutureServiceDate doc
        resultMatched result `shouldBe` True

    -- -----------------------------------------------------------------------
    -- 8. PatientAgeOutOfRange
    -- -----------------------------------------------------------------------
    describe "PatientAgeOutOfRange fires on invalid ages" $ do

      it "DOB \"1800-01-01\" (age > 130) → fires" $ do
        let doc = object ["patient" .= object ["date_of_birth" .= ("1800-01-01" :: String)]]
        result <- evalRule rulePatientAgeOutOfRange doc
        resultMatched result `shouldBe` True

      it "DOB \"2099-01-01\" (future DOB, negative age) → fires" $ do
        let doc = object ["patient" .= object ["date_of_birth" .= ("2099-01-01" :: String)]]
        result <- evalRule rulePatientAgeOutOfRange doc
        resultMatched result `shouldBe` True

      it "DOB \"1990-01-15\" (age ~36) → does NOT fire" $ do
        let doc = object ["patient" .= object ["date_of_birth" .= ("1990-01-15" :: String)]]
        result <- evalRule rulePatientAgeOutOfRange doc
        resultMatched result `shouldBe` False

      it "null DOB → does NOT fire (IS NOT NULL guard)" $ do
        let doc = object ["patient" .= object ["date_of_birth" .= Aeson.Null]]
        result <- evalRule rulePatientAgeOutOfRange doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 9. ExcessiveTotalCharges and ExtremeAmounts
    -- -----------------------------------------------------------------------
    describe "ExcessiveTotalCharges and ExtremeAmounts fire on large amounts" $ do

      it "total_charges = 800000.0 → ExcessiveTotalCharges fires, ExtremeAmounts does NOT" $ do
        let doc = object ["claim_totals" .= object ["total_charges" .= (800000.0 :: Double)]]
        r1 <- evalRule ruleExcessiveTotalCharges doc
        r2 <- evalRule ruleExtremeAmounts doc
        resultMatched r1 `shouldBe` True
        resultMatched r2 `shouldBe` False

      it "total_charges = 1500000.0 → both fire" $ do
        let doc = object ["claim_totals" .= object ["total_charges" .= (1500000.0 :: Double)]]
        r1 <- evalRule ruleExcessiveTotalCharges doc
        r2 <- evalRule ruleExtremeAmounts doc
        resultMatched r1 `shouldBe` True
        resultMatched r2 `shouldBe` True

      it "total_charges = 450.0 → neither fires" $ do
        let doc = object ["claim_totals" .= object ["total_charges" .= (450.0 :: Double)]]
        r1 <- evalRule ruleExcessiveTotalCharges doc
        r2 <- evalRule ruleExtremeAmounts doc
        resultMatched r1 `shouldBe` False
        resultMatched r2 `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 10. UnauthorizedProcedure
    -- -----------------------------------------------------------------------
    describe "UnauthorizedProcedure fires when auth missing AND amount > $5K" $ do

      it "null authorization_number + $10000 → fires" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= Aeson.Null]
              , "financial"     .= object ["claim_amount" .= (10000 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` True

      it "null authorization_number + $450 → does NOT fire (amount too low)" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= Aeson.Null]
              , "financial"     .= object ["claim_amount" .= (450 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` False

      it "present authorization_number + $10000 → does NOT fire" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= ("AUTH-XYZ" :: String)]
              , "financial"     .= object ["claim_amount" .= (10000 :: Double)]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` False

      it "null authorization_number + null amount → does NOT fire (null safe)" $ do
        let doc = object
              [ "authorization" .= object ["authorization_number" .= Aeson.Null]
              , "financial"     .= object ["claim_amount" .= Aeson.Null]
              ]
        result <- evalRule ruleUnauthorizedProcedure doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 11. SuspiciouslyLowCharge
    -- -----------------------------------------------------------------------
    describe "SuspiciouslyLowCharge fires on amount < $5" $ do

      it "$4.99 → fires" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (4.99 :: Double)]]
        result <- evalRule ruleSuspiciouslyLowCharge doc
        resultMatched result `shouldBe` True

      it "$0.01 → fires" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (0.01 :: Double)]]
        result <- evalRule ruleSuspiciouslyLowCharge doc
        resultMatched result `shouldBe` True

      it "$5.00 → does NOT fire (rule is strict < 5)" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (5.00 :: Double)]]
        result <- evalRule ruleSuspiciouslyLowCharge doc
        resultMatched result `shouldBe` False

      it "$450 → does NOT fire" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (450 :: Double)]]
        result <- evalRule ruleSuspiciouslyLowCharge doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 12. HighValueClaim
    -- -----------------------------------------------------------------------
    describe "HighValueClaim fires on amount > $50K" $ do

      it "$75000 → fires" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (75000 :: Double)]]
        result <- evalRule ruleHighValueClaim doc
        resultMatched result `shouldBe` True

      it "$50000 → does NOT fire (rule is strict > 50000)" $ do
        let doc = object ["financial" .= object ["claim_amount" .= (50000 :: Double)]]
        result <- evalRule ruleHighValueClaim doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 13. MissingProviderTaxonomy
    -- -----------------------------------------------------------------------
    describe "MissingProviderTaxonomy fires when taxonomy null AND amount > $1K" $ do

      it "null taxonomy + $5000 → fires" $ do
        let doc = object
              [ "billing_provider" .= object ["taxonomy" .= Aeson.Null]
              , "financial"        .= object ["claim_amount" .= (5000 :: Double)]
              ]
        result <- evalRule ruleMissingProviderTaxonomy doc
        resultMatched result `shouldBe` True

      it "null taxonomy + $500 → does NOT fire (amount too low)" $ do
        let doc = object
              [ "billing_provider" .= object ["taxonomy" .= Aeson.Null]
              , "financial"        .= object ["claim_amount" .= (500 :: Double)]
              ]
        result <- evalRule ruleMissingProviderTaxonomy doc
        resultMatched result `shouldBe` False

      it "\"291U00000X\" taxonomy + $5000 → does NOT fire" $ do
        let doc = object
              [ "billing_provider" .= object ["taxonomy" .= ("291U00000X" :: String)]
              , "financial"        .= object ["claim_amount" .= (5000 :: Double)]
              ]
        result <- evalRule ruleMissingProviderTaxonomy doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 14. NewProviderLargeSubmission
    -- -----------------------------------------------------------------------
    describe "NewProviderLargeSubmission fires when tenure < 90 days AND amount > $10K" $ do

      it "tenure_days=30 + $15000 → fires" $ do
        let doc = object
              [ "provider"  .= object ["tenure_days" .= (30 :: Int)]
              , "financial" .= object ["claim_amount" .= (15000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` True

      it "tenure_days=30 + $5000 → does NOT fire (amount too low)" $ do
        let doc = object
              [ "provider"  .= object ["tenure_days" .= (30 :: Int)]
              , "financial" .= object ["claim_amount" .= (5000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` False

      it "tenure_days=500 + $15000 → does NOT fire (experienced provider)" $ do
        let doc = object
              [ "provider"  .= object ["tenure_days" .= (500 :: Int)]
              , "financial" .= object ["claim_amount" .= (15000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` False

      it "tenure_days=null + $15000 → does NOT fire (null safe)" $ do
        let doc = object
              [ "provider"  .= object ["tenure_days" .= Aeson.Null]
              , "financial" .= object ["claim_amount" .= (15000 :: Double)]
              ]
        result <- evalRule ruleNewProviderLargeSubmission doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 15. TaxonomyMismatchNewProvider
    -- -----------------------------------------------------------------------
    describe "TaxonomyMismatchNewProvider fires when taxonomy null AND tenure < 90 AND amount > $5K" $ do

      it "null taxonomy + tenure=30 + $6000 → fires" $ do
        let doc = object
              [ "billing_provider" .= object ["taxonomy" .= Aeson.Null]
              , "provider"         .= object ["tenure_days" .= (30 :: Int)]
              , "financial"        .= object ["claim_amount" .= (6000 :: Double)]
              ]
        result <- evalRule ruleTaxonomyMismatchNewProvider doc
        resultMatched result `shouldBe` True

      it "null taxonomy + tenure=null + $6000 → does NOT fire (null safe)" $ do
        let doc = object
              [ "billing_provider" .= object ["taxonomy" .= Aeson.Null]
              , "provider"         .= object ["tenure_days" .= Aeson.Null]
              , "financial"        .= object ["claim_amount" .= (6000 :: Double)]
              ]
        result <- evalRule ruleTaxonomyMismatchNewProvider doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 16. HighComplexityERVisit
    -- -----------------------------------------------------------------------
    describe "HighComplexityERVisit fires on procedure 99285 AND amount > $10K" $ do

      it "procedure=\"99285\" + $15000 → fires" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("2020-01-15" :: String), "procedure_code" .= ("99285" :: String)]]
              , "financial"     .= object ["claim_amount" .= (15000 :: Double)]
              ]
        result <- evalRule ruleHighComplexityERVisit doc
        resultMatched result `shouldBe` True

      it "procedure=\"99213\" + $15000 → does NOT fire (different procedure)" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("2020-01-15" :: String), "procedure_code" .= ("99213" :: String)]]
              , "financial"     .= object ["claim_amount" .= (15000 :: Double)]
              ]
        result <- evalRule ruleHighComplexityERVisit doc
        resultMatched result `shouldBe` False

      it "procedure=\"99285\" + $5000 → does NOT fire (amount too low)" $ do
        let doc = object
              [ "service_lines" .= [object ["date_of_service" .= ("2020-01-15" :: String), "procedure_code" .= ("99285" :: String)]]
              , "financial"     .= object ["claim_amount" .= (5000 :: Double)]
              ]
        result <- evalRule ruleHighComplexityERVisit doc
        resultMatched result `shouldBe` False

    -- -----------------------------------------------------------------------
    -- 17. Real fixture NPIs pass all NPI validation rules (regression)
    -- -----------------------------------------------------------------------
    describe "Real fixture NPIs pass all NPI validation rules" $ do

      it "lab_work NPI \"1003001850\": InvalidNPIFormat does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003001850" :: String)]]
        result <- evalRule ruleInvalidNPIFormat doc
        resultMatched result `shouldBe` False

      it "lab_work NPI \"1003001850\": InvalidProviderNPI does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003001850" :: String)]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` False

      it "preventive NPI \"1003000118\": InvalidNPIFormat does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003000118" :: String)]]
        result <- evalRule ruleInvalidNPIFormat doc
        resultMatched result `shouldBe` False

      it "preventive NPI \"1003000118\": InvalidProviderNPI does NOT fire" $ do
        let doc = object ["provider" .= object ["npi" .= ("1003000118" :: String)]]
        result <- evalRule ruleInvalidProviderNPI doc
        resultMatched result `shouldBe` False
