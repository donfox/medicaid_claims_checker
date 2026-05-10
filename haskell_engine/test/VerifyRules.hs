-- Test script to verify all business rules stored in catalogue
-- Parses each rule, checks syntax, and extracts field references

module Main where

import Claims.Parser (parseRule)
import qualified Data.Text as Text
import Data.Text (Text, pack)
import System.Exit (exitFailure)
import qualified Data.Set as Set
import Text.Regex.TDFA

-- All 18 active rules from business_rules table
businessRules :: [(String, String)]
businessRules = 
  [ ("HighValueClaim", "RULE high_value_claim\nDESCRIPTION \"Claims exceeding $50,000 require manual review before payment\"\nWHEN financial.claim_amount > 50000\nTHEN REQUIRE_REVIEW \"Claim exceeds high-value threshold — manual approval required\"\nEND")
  , ("UnauthorizedProcedure", "RULE unauthorized_procedure\nDESCRIPTION \"High-value claim submitted without a valid authorization number\"\nWHEN authorization.authorization_number IS NULL\n     AND financial.claim_amount > 5000\nTHEN REJECT \"High-value claim lacks required authorization\"\nEND")
  , ("NewProviderLargeSubmission", "RULE new_provider_large_submission\nDESCRIPTION \"Large claim from a provider credentialed less than 90 days ago\"\nWHEN provider.tenure_days < 90\n     AND financial.claim_amount > 10000\nTHEN REQUIRE_REVIEW \"Large submission from newly credentialed provider\"\nEND")
  , ("SuspiciouslyLowCharge", "RULE suspicious_low_charge\nDESCRIPTION \"Charge below $5 may indicate billing manipulation or data error\"\nWHEN financial.claim_amount < 5\nTHEN FLAG_FRAUD \"Suspiciously low charge — possible billing manipulation\"\nEND")
  , ("HighValueReview", "RULE high_value_review\nDESCRIPTION \"Flag high-value claims for manual review\"\nWHEN 2300.CLM.claim_amount > 50000\nTHEN REQUIRE_REVIEW \"Exceeds high-value threshold\"\nEND")
  , ("MissingDiagnosisCodes", "RULE missing_diagnosis_codes\n\"Rejects claims that contain no diagnosis codes\"\nWHEN COUNT(claim.diagnosis_codes) = 0\nTHEN REJECT \"No diagnosis codes present on claim\";")
  , ("WeekendOfficeVisit", "RULE weekend_office_visit\nDESCRIPTION \"Office visit on weekend with elevated amount\"\nWHEN 2400.SV1.place_of_service = \"11\"\n     AND 2400.DTP.service_day_of_week = \"SAT\"\n     AND 2300.CLM.claim_amount > 500\nTHEN REQUIRE_REVIEW \"Weekend office visit requires verification\"\nEND")
  , ("HighComplexityERVisit", "RULE high_complexity_er_visit\nDESCRIPTION \"High-complexity ER visit (99285) with elevated charges requires clinical review\"\nWHEN service_lines.0.procedure_code = \"99285\"\n     AND financial.claim_amount > 10000\nTHEN REQUIRE_REVIEW \"High-complexity ER — clinical validation required\"\nEND")
  , ("MissingProviderTaxonomy", "RULE missing_provider_taxonomy\nDESCRIPTION \"Flag claims missing provider taxonomy code for specialty verification\"\nWHEN billing_provider.taxonomy IS NULL\n     AND financial.claim_amount > 1000\nTHEN REQUIRE_REVIEW \"Provider taxonomy code missing — cannot validate specialty\"\nEND")
  , ("TaxonomyMismatchNewProvider", "RULE taxonomy_mismatch_new_provider\nDESCRIPTION \"New provider with missing taxonomy on high-value claim is high risk\"\nWHEN billing_provider.taxonomy IS NULL\n     AND provider.tenure_days < 90\n     AND financial.claim_amount > 5000\nTHEN FLAG_FRAUD \"New provider with no taxonomy code submitting high-value claim\"\nEND")
  , ("MissingRequiredFields", "RULE missing_required_fields\n\"Ensures all mandatory fields are present in the claim payload\"\nWHEN claim_id IS NULL\n  OR rendering_provider.npi IS NULL\n  OR subscriber.date_of_birth IS NULL\n  OR financial.claim_amount IS NULL\nTHEN REJECT \"Missing required claim field\";")
  , ("ImpossibleDates", "RULE impossible_dates\n\"Rejects claims with service dates in the future or before 1900\"\nWHEN is_future_date(service_lines.0.date_of_service)\n  OR is_date_before(service_lines.0.date_of_service, \"1900-01-01\")\nTHEN REJECT \"Impossible service date detected\";")
  , ("InvalidProviderNPI", "RULE invalid_provider_npi\n\"Validates that the billing provider NPI passes Luhn-10 checksum\"\nWHEN provider.npi IS NOT NULL\n  AND NOT is_valid_npi(provider.npi)\nTHEN REJECT \"Provider NPI fails Luhn-10 validation\";")
  , ("FutureServiceDate", "RULE future_service_date\n\"Rejects claims where the date of service has not yet occurred\"\nWHEN is_future_date(service_lines.0.date_of_service)\nTHEN REJECT \"Service date is in the future\";")
  , ("InvalidNPIFormat", "RULE invalid_npi_format\n\"Rejects claims where the billing provider NPI is not exactly 10 digits\"\nWHEN provider.npi IS NOT NULL\n  AND NOT is_npi_format(provider.npi)\nTHEN REJECT \"Provider NPI is not a valid 10-digit number\";")
  , ("ExtremeAmounts", "RULE extreme_amounts\n\"Flags claims with total charges exceeding $1,000,000\"\nWHEN claim_totals.total_charges > 1000000\nTHEN FLAG_FRAUD \"Extreme billing amount exceeds $1M\";")
  , ("ExcessiveTotalCharges", "RULE excessive_total_charges\n\"Flags claims with total charges exceeding $750,000 as potential fraud\"\nWHEN claim_totals.total_charges > 750000\nTHEN FLAG_FRAUD \"Total charges exceed $750K threshold\";")
  , ("PatientAgeOutOfRange", "RULE patient_age_out_of_range\n\"Rejects claims where the patient age is negative or exceeds 130 years\"\nWHEN patient.date_of_birth IS NOT NULL\n  AND NOT is_age_valid(patient.date_of_birth, 0, 130)\nTHEN REJECT \"Patient age is out of valid range (0-130)\";")
  ]

-- Extract field references from rule text using regex
extractFieldReferences :: String -> [String]
extractFieldReferences ruleText =
  let -- Match dotted paths like "financial.claim_amount", "service_lines.0.procedure_code"
      pattern = "[a-zA-Z_][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)*" :: String
      matches = ruleText =~ pattern :: [[String]]
  in concatMap id matches

main :: IO ()
main = do
  putStrLn "VERIFYING BUSINESS RULES"
  putStrLn "========================"
  putStrLn ""
  
  let results = map verifyRule businessRules
  
  -- Summary counts
  let validCount = length $ filter fst results
  let invalidCount = length results - validCount
  
  putStrLn $ "TOTAL_RULES=" ++ show (length results)
  putStrLn $ "VALID_RULES=" ++ show validCount
  putStrLn $ "INVALID_RULES=" ++ show invalidCount
  putStrLn ""
  
  -- Print detailed results
  mapM_ printResult (zip businessRules results)
  
  if invalidCount > 0 then exitFailure else return ()

verifyRule :: (String, String) -> Bool
verifyRule (name, text) =
  case parseRule (pack text) of
    Left err -> False
    Right _ -> True

printResult :: ((String, String), Bool) -> IO ()
printResult ((name, text), isValid) = do
  putStrLn $ "RULE=" ++ name
  putStrLn $ "VALID=" ++ show isValid
  
  -- Extract and show field references
  let fields = extractFieldReferences text
  let uniqueFields = Set.toList $ Set.fromList fields
  putStrLn $ "FIELD_COUNT=" ++ show (length uniqueFields)
  mapM_ (\f -> putStrLn $ "  FIELD=" ++ f) uniqueFields
  
  putStrLn ""
