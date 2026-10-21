-- ============================================================================
-- Redundancy levels: a rule set that overlaps on purpose
-- ============================================================================
-- Paste into the Rules page (or POST to /api/check-redundancy) to see the
-- redundancy checker report every level:
--   Level 1 — Exact duplicate   (same condition, same action)
--   Level 2 — Subsumption       (one condition implies the other, same action)
--   Level 3 — Shadowed          (one condition implies the other, different action)
--   Level 4 — Condition overlap (same fields, overlapping ranges)
--
-- The claims in ../claims/redundancy/ show which of these rules fire
-- together; manifest.json lists the expected matches for each. Every field
-- is one the claim converter produces, so the rules pass the Rules page
-- schema check.
-- ============================================================================


-- GROUP A: claim amount  (Levels 1, 2, 3, 4)

RULE high_amount_50k "Flag claims over $50,000"
WHEN financial.claim_amount > 50000
THEN FLAG_FRAUD "Claim exceeds $50,000 threshold";

-- Level 1 — exact duplicate of high_amount_50k
RULE high_amount_50k_dup "Duplicate: also flags claims over $50,000"
WHEN financial.claim_amount > 50000
THEN FLAG_FRAUD "Claim exceeds $50,000 threshold";

-- Level 2 — subsumption: > 100000 implies > 50000, same action
RULE extreme_amount_100k "Flag claims over $100,000"
WHEN financial.claim_amount > 100000
THEN FLAG_FRAUD "Claim exceeds $100,000 — extreme amount";

-- Level 3 — shadowed: > 75000 implies > 50000, but REJECT instead of FLAG_FRAUD
RULE high_amount_reject "Reject claims over $75,000"
WHEN financial.claim_amount > 75000
THEN REJECT "Claim over $75,000 auto-rejected";

-- Level 4 — overlap: 40,000–60,000 overlaps > 50,000
RULE mid_range_review "Review claims in the $40k–$60k range"
WHEN financial.claim_amount BETWEEN 40000 AND 60000
THEN REQUIRE_REVIEW "Mid-range claim needs manual review";


-- GROUP B: provider tenure  (Levels 2, 3, 4)
-- provider.tenure_days comes only from JSON claims; X12 conversion leaves it empty.

RULE new_provider_90 "Flag new providers (< 90 days)"
WHEN provider.tenure_days < 90
THEN FLAG_FRAUD "Provider credentialed fewer than 90 days";

-- Level 2 — subsumption: < 30 implies < 90, same action
RULE very_new_provider_30 "Flag very new providers (< 30 days)"
WHEN provider.tenure_days < 30
THEN FLAG_FRAUD "Provider credentialed fewer than 30 days";

-- Level 3 — shadowed: < 60 implies < 90, different action
RULE new_provider_reject "Reject providers under 60 days"
WHEN provider.tenure_days < 60
THEN REJECT "Provider too new — reject claim";

-- Level 4 — overlap: 0–120 overlaps < 90
RULE provider_probation "Review providers in the probation window (0–120 days)"
WHEN provider.tenure_days BETWEEN 0 AND 120
THEN REQUIRE_REVIEW "Provider in probation window";


-- GROUP C: place of service  (Levels 1, 3)

RULE er_visit_flag "Flag emergency room claims"
WHEN claim_details.place_of_service = "23"
THEN FLAG_FRAUD "Emergency room visit flagged for review";

-- Level 1 — exact duplicate
RULE er_visit_flag_copy "Duplicate ER flag"
WHEN claim_details.place_of_service = "23"
THEN FLAG_FRAUD "Emergency room visit flagged for review";

-- Level 3 — shadowed: same condition, different action
RULE er_visit_reject "Reject ER claims outright"
WHEN claim_details.place_of_service = "23"
THEN REJECT "ER claims auto-rejected by policy";


-- GROUP D: compound conditions  (Levels 2, 4)

-- Level 2 — implies high_amount_50k and new_provider_90 (same action)
RULE high_amount_new_provider "High amount from a new provider"
WHEN financial.claim_amount > 50000 AND provider.tenure_days < 90
THEN FLAG_FRAUD "High amount from new provider";

-- Level 4 — shares the amount field with mid_range_review and the tenure
-- field with provider_probation
RULE moderate_amount_newer_provider "Moderate amount from a newer provider"
WHEN financial.claim_amount > 30000 AND provider.tenure_days < 120
THEN REQUIRE_REVIEW "Moderate amount from newer provider";


-- GROUP E: principal diagnosis, text equality  (Levels 1, 3)
-- Diagnosis codes are stored as sent in the 837, without the dot (E11.9 -> E119).

RULE diabetes_flag "Flag claims with principal diagnosis E11.9"
WHEN diagnosis_codes.0.code = "E119"
THEN FLAG_FRAUD "Diabetes diagnosis flagged for review";

-- Level 1 — exact duplicate
RULE diabetes_flag_dup "Duplicate diabetes flag"
WHEN diagnosis_codes.0.code = "E119"
THEN FLAG_FRAUD "Diabetes diagnosis flagged for review";

-- Level 3 — shadowed: same condition, REJECT instead of FLAG_FRAUD
RULE diabetes_reject "Reject diabetes claims outright"
WHEN diagnosis_codes.0.code = "E119"
THEN REJECT "Diabetes claims auto-rejected";

-- No redundancy with the above: a different value of the same field
RULE hypertension_review "Review claims with principal diagnosis I10"
WHEN diagnosis_codes.0.code = "I10"
THEN REQUIRE_REVIEW "Hypertension claim — manual review";


-- GROUP F: BETWEEN ranges inside EXISTS  (Levels 1, 4)
-- On an institutional claim, room-and-board lines (revenue code 0120) carry
-- the number of inpatient days in units.

RULE stay_7_14 "Review stays of 7–14 days"
WHEN EXISTS day IN service_lines WHERE day.revenue_code = "0120" AND day.units BETWEEN 7 AND 14
THEN REQUIRE_REVIEW "Medium-length stay review";

-- Level 1 — exact duplicate
RULE stay_7_14_dup "Duplicate: also reviews 7–14 day stays"
WHEN EXISTS day IN service_lines WHERE day.revenue_code = "0120" AND day.units BETWEEN 7 AND 14
THEN REQUIRE_REVIEW "Medium-length stay review";

-- Level 4 — overlap: 10–21 intersects 7–14 at 10–14
RULE stay_10_21 "Flag stays of 10–21 days"
WHEN EXISTS day IN service_lines WHERE day.revenue_code = "0120" AND day.units BETWEEN 10 AND 21
THEN FLAG_FRAUD "Extended stay flagged";

-- No overlap: 1–5 and 7–14 are disjoint
RULE stay_1_5 "Review short stays of 1–5 days"
WHEN EXISTS day IN service_lines WHERE day.revenue_code = "0120" AND day.units BETWEEN 1 AND 5
THEN REQUIRE_REVIEW "Short stay — possible premature discharge";


-- GROUP G: OR conditions  (Levels 1, 2, 4)

RULE high_or_er "Flag a high amount or an ER visit"
WHEN financial.claim_amount > 50000 OR claim_details.place_of_service = "23"
THEN FLAG_FRAUD "High amount or ER — flagged";

-- Level 1 — exact duplicate
RULE high_or_er_dup "Duplicate: high amount or ER"
WHEN financial.claim_amount > 50000 OR claim_details.place_of_service = "23"
THEN FLAG_FRAUD "High amount or ER — flagged";

-- Level 2 — the amount arm alone implies the OR, same action
RULE high_amount_only "Flag a high amount (no OR)"
WHEN financial.claim_amount > 50000
THEN FLAG_FRAUD "High amount flagged";

-- Level 4 — shares the amount field with the OR rule
RULE moderate_amount_flag "Flag moderate amounts"
WHEN financial.claim_amount > 30000
THEN FLAG_FRAUD "Moderate amount flagged";


-- GROUP H: NOT  (Levels 1, 3)
-- Claim frequency code (CLM05-3): 1 original, 7 replacement, 8 void.

RULE not_original_flag "Flag replacement and void claims"
WHEN NOT claim_details.frequency_code = "1"
THEN FLAG_FRAUD "Non-original claim flagged";

-- Level 1 — exact duplicate
RULE not_original_flag_dup "Duplicate: flag replacement and void claims"
WHEN NOT claim_details.frequency_code = "1"
THEN FLAG_FRAUD "Non-original claim flagged";

-- Level 3 — shadowed: same negated condition, different action
RULE not_original_reject "Reject replacement and void claims"
WHEN NOT claim_details.frequency_code = "1"
THEN REJECT "Non-original claim auto-rejected";


-- GROUP I: multi-field partial overlap  (Levels 2, 4)
-- 207RC0000X is the cardiovascular disease taxonomy; POS 21 is inpatient hospital.

RULE cardio_high_amount "Cardiology claim over $50,000"
WHEN financial.claim_amount > 50000 AND billing_provider.taxonomy = "207RC0000X"
THEN FLAG_FRAUD "High-amount cardiology claim";

-- Level 4 — shares the amount condition with cardio_high_amount, differs on the second field
RULE inpatient_high_amount "Inpatient-hospital claim over $50,000"
WHEN financial.claim_amount > 50000 AND claim_details.place_of_service = "21"
THEN REQUIRE_REVIEW "High-amount inpatient claim";

-- Shares both fields with cardio_high_amount at a lower threshold
RULE cardio_moderate "Cardiology claim over $20,000"
WHEN financial.claim_amount > 20000 AND billing_provider.taxonomy = "207RC0000X"
THEN REQUIRE_REVIEW "Moderate cardiology claim review";
