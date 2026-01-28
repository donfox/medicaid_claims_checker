-- Example fraud detection rules for X12 837P claims

-- Rule 1: Unusually high claim amount
RULE high_claim_amount "Flag claims with unusually high amounts"
WHEN 2300.CLM.claim_amount > 50000.0
THEN FLAG_FRAUD "Claim amount exceeds $50,000 threshold";

-- Rule 2: Multiple claims same day for same patient
RULE duplicate_same_day "Detect potential duplicate claims"
WHEN COUNT(2300) > 5
THEN [REQUIRE_REVIEW "Multiple claims submitted on same day", RISK_SCORE 60];

-- Rule 3: Service date after submission date
RULE future_service_date "Service date is in the future"
WHEN 2400.DTP.service_date > 2300.DTP.submission_date
THEN REJECT "Service date cannot be after submission date";

-- Rule 4: Unbundling detection - multiple procedures that should be bundled
RULE unbundling_check "Check for unbundled procedures"
WHEN EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99213" 
     AND EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99214"
THEN FLAG_FRAUD "Possible unbundling - multiple E&M codes on same claim";

-- Rule 5: Services by deceased provider
RULE deceased_provider "Provider is marked as deceased"
WHEN 2010.NM1.provider_status = "deceased"
THEN REJECT "Cannot submit claim for deceased provider";

-- Rule 6: Excessive daily charges
RULE excessive_daily_charges "Total daily charges exceed reasonable limit"
WHEN FORALL 2400 WHERE 2400.SV1.line_charge > 0.0
     AND COUNT(2400) * 500.0 < 2300.CLM.claim_amount
THEN [FLAG_FRAUD "Daily charges appear excessive", RISK_SCORE 75];

-- Rule 7: Missing required diagnosis code
RULE missing_diagnosis "Required diagnosis code is missing"
WHEN 2300.HI.diagnosis_code IS NULL
THEN REJECT "Diagnosis code is required";

-- Rule 8: Service location inconsistency
RULE location_mismatch "Service location doesn't match provider type"
WHEN 2400.SV1.place_of_service = "11" 
     AND 2010.NM1.provider_type != "office"
THEN REQUIRE_REVIEW "Service location inconsistent with provider type";

-- Rule 9: Age-inappropriate service
RULE age_inappropriate "Service not appropriate for patient age"
WHEN 2010.NM1.patient_age < 18 
     AND 2400.SV1.procedure_code = "99385"
THEN FLAG_FRAUD "Adult preventive service billed for minor";

-- Rule 10: Unusual billing pattern
RULE unusual_pattern "Unusual number of high-value services"
WHEN COUNT(2400) > 20 
     AND FORALL 2400 WHERE 2400.SV1.line_charge > 1000.0
THEN [RISK_SCORE 85, REQUIRE_REVIEW "Unusual high-value billing pattern"];
