-- Valid DSL Rules for Testing
-- All rules should parse successfully

RULE high_amount
DESCRIPTION "Flag claims over $50,000"
WHEN claim.amount > 50000
THEN FLAG_FRAUD "High claim amount"
END

RULE low_value "Flag suspiciously low charges" WHEN total_charge < 10 THEN REQUIRE_REVIEW "Unusually low charge";

RULE invalid_state
DESCRIPTION "Reject claims from invalid state"
WHEN provider.state = "XX"
THEN REJECT "Invalid state code"
END

RULE high_risk_combo
DESCRIPTION "Flag high amount claims from new providers"
WHEN claim.amount > 25000 AND provider.tenure_days < 90
THEN FLAG_FRAUD "New provider with high claim"
END

RULE urgent_review
DESCRIPTION "Review claims with specific procedure codes"
WHEN procedure_code = "99285" OR procedure_code = "99284"
THEN REQUIRE_REVIEW "ER procedure code detected"
END

RULE missing_auth
DESCRIPTION "Flag claims without authorization"
WHEN NOT authorization_number IS NOT NULL
THEN FLAG_FRAUD "Missing authorization"
END

RULE complex_fraud
DESCRIPTION "Complex fraud detection rule"
WHEN (claim.amount > 10000 OR claim.units > 50) AND provider.risk_score > 75
THEN FLAG_FRAUD "Multiple risk factors"
END

RULE claim_loop_check
DESCRIPTION "Check claim loop fields"
WHEN 2300.CLM.claim_amount > 100000
THEN RISK_SCORE 85
END

RULE multi_action
DESCRIPTION "Apply multiple actions for severe fraud"
WHEN claim.amount > 500000
THEN [FLAG_FRAUD "Extreme amount", RISK_SCORE 100, REQUIRE_REVIEW "Manual verification required"]
END

RULE duplicate_detection
DESCRIPTION "Detect potential duplicate submissions"
WHEN COUNT(2300.CLM) > 5
THEN FLAG_FRAUD "Excessive claim segments"
END
