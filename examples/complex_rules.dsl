-- Complex Claims Integrity Rules
-- These rules demonstrate advanced DSL features for healthcare claims validation

-- Rule 1: Emergency room claim with high charges and no emergency diagnosis
-- Uses nested AND/OR with NOT to catch ER claims missing appropriate justification
RULE er_claim_no_emergency_dx
DESCRIPTION "ER claim lacks emergency diagnosis codes"
WHEN 2400.SV1.place_of_service = "23"
     AND 2300.CLM.claim_amount > 5000
     AND NOT (2300.HI.diagnosis_code = "S06"
              OR 2300.HI.diagnosis_code = "I21"
              OR 2300.HI.diagnosis_code = "R55"
              OR 2300.HI.diagnosis_code = "J96")
THEN [REJECT "ER claim over $5,000 missing emergency diagnosis", RISK_SCORE 90]
END

-- Rule 2: Inpatient stay with excessive service lines and high total
-- Combines COUNT quantifier with amount check for suspicious billing patterns
RULE excessive_inpatient_billing
DESCRIPTION "Inpatient claim with unusually many service lines and high total"
WHEN 2300.CLM.facility_type = "Inpatient"
     AND COUNT(2400) > 30
     AND 2300.CLM.claim_amount > 200000
THEN [FLAG_FRAUD "Excessive inpatient service lines with high total", RISK_SCORE 85, REQUIRE_REVIEW "Manual audit recommended"]
END

-- Rule 3: Outpatient surgery billed at inpatient rates
-- Cross-references place of service against claim type
RULE outpatient_billed_as_inpatient
DESCRIPTION "Outpatient procedure location but inpatient billing codes"
WHEN 2400.SV1.place_of_service = "22"
     AND 2300.CLM.facility_type = "Inpatient"
     AND 2300.CLM.claim_amount > 10000
THEN [REJECT "Place of service indicates outpatient but billed as inpatient", RISK_SCORE 80]
END

-- Rule 4: Evaluation and Management code stacking
-- Detects multiple high-level E&M codes on the same claim
RULE em_code_stacking
DESCRIPTION "Multiple high-level E&M codes billed together"
WHEN EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99215"
     AND EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99214"
     AND COUNT(2400) > 5
THEN [FLAG_FRAUD "Multiple high-level E&M codes on same claim", RISK_SCORE 75, REQUIRE_REVIEW "Possible upcoding or code stacking"]
END

-- Rule 5: Weekend services at office-based facility
-- Office visits on weekends may indicate phantom billing
RULE weekend_office_visits
DESCRIPTION "Office visit services rendered on weekends"
WHEN 2400.SV1.place_of_service = "11"
     AND 2400.DTP.service_day_of_week = "SAT"
     AND 2300.CLM.claim_amount > 500
THEN REQUIRE_REVIEW "Office visit billed on weekend - verify provider schedule"
END

-- Rule 6: High-value claim from new provider with multiple flags
-- Complex multi-factor risk assessment
RULE new_provider_high_risk
DESCRIPTION "New provider submitting high-value claims with risk indicators"
WHEN 2010.NM1.provider_tenure_days < 90
     AND 2300.CLM.claim_amount > 25000
     AND (COUNT(2400) > 15 OR 2300.CLM.claim_amount > 75000)
     AND NOT 2010.NM1.provider_specialty = "surgery"
THEN [FLAG_FRAUD "New provider with high-value suspicious claim", RISK_SCORE 95, REQUIRE_REVIEW "Priority review - new provider risk pattern"]
END

-- Rule 7: Service line amounts that don't sum to total
-- Uses FORALL to check all service lines have valid charges
RULE service_line_validation
DESCRIPTION "Service lines with zero or negative charges"
WHEN NOT FORALL 2400 WHERE 2400.SV1.line_charge > 0
     AND 2300.CLM.claim_amount > 0
THEN [REJECT "Service lines contain zero or negative charges", RISK_SCORE 70]
END

-- Rule 8: Physical therapy excessive visits
-- Domain-specific rule for PT claims
RULE pt_excessive_visits
DESCRIPTION "Physical therapy claim exceeds reasonable visit count"
WHEN 2300.CLM.claim_type = "Professional"
     AND (EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "97110"
          OR EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "97140"
          OR EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "97530")
     AND COUNT(2400) > 12
     AND 2300.CLM.claim_amount > 3000
THEN [REQUIRE_REVIEW "Physical therapy visits exceed typical session count", RISK_SCORE 60]
END

-- Rule 9: Anesthesia without surgical procedure
-- Cross-checks anesthesia codes against surgical codes
RULE anesthesia_without_surgery
DESCRIPTION "Anesthesia billed without corresponding surgical procedure"
WHEN EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "00100"
     AND NOT EXISTS 2400.SV1 WHERE 2400.SV1.procedure_type = "surgical"
     AND 2300.CLM.claim_amount > 2000
THEN [REJECT "Anesthesia code billed without surgical procedure", RISK_SCORE 85]
END

-- Rule 10: Durable Medical Equipment with invalid location
-- DME should not be billed from certain facility types
RULE dme_invalid_location
DESCRIPTION "DME billed from invalid facility type"
WHEN (EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "E0601"
      OR EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "K0823"
      OR EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "A4253")
     AND (2400.SV1.place_of_service = "21"
          OR 2400.SV1.place_of_service = "23")
     AND 2300.CLM.claim_amount > 500
THEN [REJECT "DME codes billed from inpatient or ER facility", RISK_SCORE 80]
END

-- Rule 11: Modifier 59 abuse detection
-- Checks for excessive use of distinct procedure modifier
RULE modifier_59_abuse
DESCRIPTION "Excessive use of modifier 59 for distinct procedures"
WHEN COUNT(2400) > 8
     AND EXISTS 2400.SV1 WHERE 2400.SV1.modifier_1 = "59"
     AND EXISTS 2400.SV1 WHERE 2400.SV1.modifier_2 = "59"
     AND 2300.CLM.claim_amount > 5000
THEN [FLAG_FRAUD "Multiple modifier 59 codes suggesting unbundling", RISK_SCORE 80, REQUIRE_REVIEW "Review for National Correct Coding Initiative compliance"]
END

-- Rule 12: Comprehensive claim integrity check
-- Multi-condition rule combining many validation factors
RULE comprehensive_integrity_check
DESCRIPTION "Multi-factor claim integrity assessment"
WHEN (2300.CLM.claim_amount > 100000
      OR (2300.CLM.claim_amount > 50000 AND COUNT(2400) > 20))
     AND NOT 2300.CLM.facility_type = "Inpatient"
     AND NOT 2300.CLM.authorization_number IS NOT NULL
     AND 2010.NM1.provider_risk_score > 50
THEN [FLAG_FRAUD "Multiple integrity risk factors detected", RISK_SCORE 95, REQUIRE_REVIEW "High-priority comprehensive review required", REJECT "Claim held pending integrity review"]
END
