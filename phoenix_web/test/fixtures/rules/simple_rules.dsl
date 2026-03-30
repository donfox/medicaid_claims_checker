-- Simple rule examples for testing

RULE simple_amount_check "Check if claim amount is over 10000"
WHEN 2300.CLM.claim_amount > 10000.0
THEN FLAG_FRAUD "High claim amount";

RULE reject_null_diagnosis "Reject claims without diagnosis"
WHEN 2300.HI.diagnosis_code IS NULL
THEN REJECT "Missing diagnosis code";

RULE low_risk_review "Review claims with specific procedure"
WHEN 2400.SV1.procedure_code = "99213"
THEN REQUIRE_REVIEW "Standard office visit";
