-- ============================================================================
-- DSL examples
-- ============================================================================
-- Rules showing language features the seeded business rules don't use:
-- nested EXISTS, NOT EXISTS, FORALL, COUNT, in_list, starts_with, MATCHES,
-- has_procedure, is_age_valid, indexed paths and multiple actions. Paste any
-- of them into the Rules page to try them; every field is one the claim
-- converter produces, so they pass the schema check.
--
-- These are examples, not policy. The thresholds are illustrative.
-- docs/SYNTAX_GUIDE.md describes each construct.
-- ============================================================================


-- ER claim over $5,000 with no emergency-type diagnosis.
-- NOT EXISTS over the diagnosis list; starts_with matches an ICD-10 category.
RULE er_claim_no_emergency_dx
DESCRIPTION "ER claim over $5,000 lacks an emergency diagnosis"
WHEN claim_details.place_of_service = "23"
     AND financial.claim_amount > 5000
     AND NOT EXISTS dx IN diagnosis_codes
         WHERE starts_with(dx.code, "S06") OR starts_with(dx.code, "I21")
            OR starts_with(dx.code, "R55") OR starts_with(dx.code, "J96")
THEN [REQUIRE_REVIEW "ER claim over $5,000 without an emergency diagnosis", RISK_SCORE 70]
END

-- Two high-level E&M codes on one claim. Two named EXISTS over the same list.
RULE em_code_stacking
DESCRIPTION "99214 and 99215 billed on the same claim"
WHEN EXISTS a IN service_lines WHERE a.procedure_code = "99215"
     AND EXISTS b IN service_lines WHERE b.procedure_code = "99214"
THEN [FLAG_FRAUD "Multiple high-level E&M codes on one claim", REQUIRE_REVIEW "Possible upcoding"]
END

-- Physical therapy with many lines. in_list inside EXISTS, plus COUNT.
RULE pt_many_sessions
DESCRIPTION "Physical therapy claim with more than 12 service lines"
WHEN EXISTS line IN service_lines WHERE in_list(line.procedure_code, ["97110", "97140", "97530"])
     AND COUNT(service_lines) > 12
     AND financial.claim_amount > 3000
THEN REQUIRE_REVIEW "Physical therapy visits exceed typical session count"
END

-- Anesthesia (CPT 00100–01999) with no surgical code (10000–69999) on the claim.
-- MATCHES takes a POSIX regular expression.
RULE anesthesia_without_surgery
DESCRIPTION "Anesthesia billed without a surgical procedure"
WHEN EXISTS line IN service_lines WHERE line.procedure_code MATCHES "^0[01][0-9]{3}$"
     AND NOT EXISTS line IN service_lines WHERE line.procedure_code MATCHES "^[1-6][0-9]{4}$"
THEN REJECT "Anesthesia code billed without a surgical procedure"
END

-- Durable medical equipment billed from an inpatient or ER setting.
RULE dme_invalid_location
DESCRIPTION "DME billed from inpatient hospital or emergency room"
WHEN EXISTS line IN service_lines
     WHERE in_list(line.procedure_code, ["E0601", "K0823", "A4253"])
       AND in_list(line.place_of_service, ["21", "23"])
THEN REJECT "DME codes billed from an inpatient or ER setting"
END

-- Every line has a positive charge. FORALL is only true when every line
-- definitely passes, so NOT FORALL catches a zero or negative charge.
RULE nonpositive_line_charge
DESCRIPTION "A service line has a zero or negative charge"
WHEN NOT FORALL line IN service_lines WHERE line.charge_amount > 0
THEN REJECT "Service lines contain zero or negative charges"
END

-- Adult preventive visit (99385) for a patient aged 0–17.
-- has_procedure searches every service line; is_age_valid checks an age range.
RULE adult_preventive_for_minor
DESCRIPTION "Adult preventive visit code billed for a minor"
WHEN claim.has_procedure "99385"
     AND is_age_valid(patient.date_of_birth, 0, 17)
THEN FLAG_FRAUD "Adult preventive service billed for a minor"
END

-- Principal diagnosis by index: a costly claim whose principal diagnosis is a
-- routine exam (Z00.x).
RULE costly_routine_exam
DESCRIPTION "Routine-exam principal diagnosis on a claim over $1,000"
WHEN starts_with(diagnosis_codes.0.code, "Z00")
     AND financial.claim_amount > 1000
THEN REQUIRE_REVIEW "Routine exam billed above $1,000"
END

-- Dental restoration or root canal without a tooth number.
-- A nested field inside EXISTS.
RULE dental_missing_tooth
DESCRIPTION "Crown or root canal billed without a tooth number"
WHEN EXISTS line IN service_lines
     WHERE line.procedure_code MATCHES "^D(27|33)"
       AND line.tooth_info.tooth_number IS NULL
THEN REQUIRE_REVIEW "Tooth number required for crowns and root canals"
END

-- Cardiac procedure billed by a non-cardiology provider.
-- The NOT starts_with compares a provider field from outside the EXISTS.
RULE cardiac_procedure_non_cardiology
DESCRIPTION "Echo or cardiac catheterization billed outside cardiology"
WHEN EXISTS line IN service_lines WHERE in_list(line.procedure_code, ["93306", "93458", "92928"])
     AND NOT starts_with(billing_provider.taxonomy, "207RC")
THEN REQUIRE_REVIEW "Cardiac procedure billed by a non-cardiology provider"
END
