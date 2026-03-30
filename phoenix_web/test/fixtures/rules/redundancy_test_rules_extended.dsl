-- ============================================================================
-- Extended Redundancy Test Rules  (Groups E–I)
-- ============================================================================
-- Supplements the base redundancy_test_rules.dsl with edge cases:
--   E — String / diagnosis-code equality
--   F — BETWEEN vs BETWEEN range overlaps
--   G — OR-condition redundancy
--   H — NOT / negation redundancy
--   I — Multi-field partial overlap (shared subset of conditions)
-- ============================================================================


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP E: String / Diagnosis-Code Equality  (Levels 1, 3)
-- ──────────────────────────────────────────────────────────────────────────────

RULE diabetes_flag "Flag diabetes claims"
WHEN 2300.HI.diagnosis_code = "E11.9"
THEN FLAG_FRAUD "Diabetes diagnosis flagged for review";

-- Level 1 — Exact Duplicate (same condition + same action)
RULE diabetes_flag_dup "Duplicate diabetes flag"
WHEN 2300.HI.diagnosis_code = "E11.9"
THEN FLAG_FRAUD "Diabetes diagnosis flagged for review";

-- Level 3 — Shadowed: same condition, different action (REJECT vs FLAG_FRAUD)
RULE diabetes_reject "Reject diabetes claims outright"
WHEN 2300.HI.diagnosis_code = "E11.9"
THEN REJECT "Diabetes claims auto-rejected";

-- Independent string rule (no redundancy with above — different field value)
RULE hypertension_review "Review hypertension claims"
WHEN 2300.HI.diagnosis_code = "I10"
THEN REQUIRE_REVIEW "Hypertension claim — manual review";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP F: BETWEEN vs BETWEEN Range Overlaps  (Levels 1, 4)
-- ──────────────────────────────────────────────────────────────────────────────

RULE stay_7_14 "Review stays 7–14 days"
WHEN 2300.CLM.days_stay BETWEEN 7 AND 14
THEN REQUIRE_REVIEW "Medium-length stay review";

-- Level 1 — Exact Duplicate (identical BETWEEN range + same action)
RULE stay_7_14_dup "Duplicate: also reviews 7–14 day stays"
WHEN 2300.CLM.days_stay BETWEEN 7 AND 14
THEN REQUIRE_REVIEW "Medium-length stay review";

-- Level 4 — Overlap: range 10–21 overlaps with 7–14 (intersection: 10–14)
RULE stay_10_21 "Flag long stays 10–21 days"
WHEN 2300.CLM.days_stay BETWEEN 10 AND 21
THEN FLAG_FRAUD "Extended stay flagged";

-- No overlap with above — disjoint range (1–5 vs 7–14)
RULE stay_1_5 "Review short stays 1–5 days"
WHEN 2300.CLM.days_stay BETWEEN 1 AND 5
THEN REQUIRE_REVIEW "Short stay — possible premature discharge";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP G: OR-Condition Redundancy  (Levels 1, 2, 4)
-- ──────────────────────────────────────────────────────────────────────────────

RULE high_or_er "Flag high amount OR ER visit"
WHEN 2300.CLM.claim_amount > 50000 OR 2400.SV1.place_of_service = "23"
THEN FLAG_FRAUD "High amount or ER — flagged";

-- Level 1 — Exact Duplicate (same OR condition + same action)
RULE high_or_er_dup "Duplicate: high amount OR ER"
WHEN 2300.CLM.claim_amount > 50000 OR 2400.SV1.place_of_service = "23"
THEN FLAG_FRAUD "High amount or ER — flagged";

-- Level 2 — Subsumption: single conjunct is LESS restrictive than the OR,
-- so the OR subsumes any claim that matches JUST the amount arm.
-- NOTE: Whether the checker detects this depends on OR-implication support.
-- amount > 50000 alone is subsumed by (amount > 50000 OR POS="23").
RULE high_amount_only "Flag high amount (no OR)"
WHEN 2300.CLM.claim_amount > 50000
THEN FLAG_FRAUD "High amount flagged";

-- Level 4 — Overlap: shares claim_amount field with the OR rule
RULE moderate_amount_flag "Flag moderate amounts"
WHEN 2300.CLM.claim_amount > 30000
THEN FLAG_FRAUD "Moderate amount flagged";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP H: NOT / Negation Redundancy  (Levels 1, 3)
-- ──────────────────────────────────────────────────────────────────────────────

RULE not_outpatient_flag "Flag non-outpatient claims"
WHEN NOT 2300.CLM.facility_type = "Outpatient"
THEN FLAG_FRAUD "Non-outpatient claim flagged";

-- Level 1 — Exact Duplicate
RULE not_outpatient_flag_dup "Duplicate: flag non-outpatient"
WHEN NOT 2300.CLM.facility_type = "Outpatient"
THEN FLAG_FRAUD "Non-outpatient claim flagged";

-- Level 3 — Shadowed: same negated condition, different action
RULE not_outpatient_reject "Reject non-outpatient claims"
WHEN NOT 2300.CLM.facility_type = "Outpatient"
THEN REJECT "Non-outpatient auto-rejected";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP I: Multi-Field Partial Overlap  (Level 4)
-- ──────────────────────────────────────────────────────────────────────────────
-- Two compound rules that share SOME fields but differ on others.
-- Neither subsumes the other, but the shared fields overlap.

RULE cardio_high_amount "Cardiology + high amount"
WHEN 2300.CLM.claim_amount > 50000 AND 2010.NM1.provider_specialty = "cardiology"
THEN FLAG_FRAUD "High-amount cardiology claim";

-- Level 4 — Overlap: shares claim_amount > 50000 with above,
-- but second conjunct differs (days_stay vs specialty)
RULE long_stay_high_amount "Long stay + high amount"
WHEN 2300.CLM.claim_amount > 50000 AND 2300.CLM.days_stay > 14
THEN REQUIRE_REVIEW "High-amount long-stay claim";

-- Another partial overlap: shares specialty field with cardio_high_amount
-- but amount threshold differs
RULE cardio_moderate "Cardiology + moderate amount"
WHEN 2300.CLM.claim_amount > 20000 AND 2010.NM1.provider_specialty = "cardiology"
THEN REQUIRE_REVIEW "Moderate cardiology claim review";
