-- ============================================================================
-- Redundancy Test Rules
-- ============================================================================
-- A set of rules that intentionally overlap so the RedundancyChecker
-- can report all four levels:
--   Level 1 — Exact Duplicate   (identical condition + action)
--   Level 2 — Subsumption       (condition implies + same action)
--   Level 3 — Shadowed          (condition implies + different action)
--   Level 4 — Condition Overlap  (same fields, overlapping ranges)
-- ============================================================================


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP A: High-Amount Rules  (Levels 1, 2, 3, 4)
-- ──────────────────────────────────────────────────────────────────────────────

RULE high_amount_50k "Flag claims over $50,000"
WHEN 2300.CLM.claim_amount > 50000
THEN FLAG_FRAUD "Claim exceeds $50,000 threshold";

-- Level 1 — Exact Duplicate of high_amount_50k
RULE high_amount_50k_dup "Duplicate: also flags claims over $50,000"
WHEN 2300.CLM.claim_amount > 50000
THEN FLAG_FRAUD "Claim exceeds $50,000 threshold";

-- Level 2 — Subsumption: > 100000 implies > 50000, same action type
RULE extreme_amount_100k "Flag claims over $100,000"
WHEN 2300.CLM.claim_amount > 100000
THEN FLAG_FRAUD "Claim exceeds $100,000 — extreme amount";

-- Level 3 — Shadowed: > 75000 implies > 50000, but REJECT vs FLAG_FRAUD
RULE high_amount_reject "Reject claims over $75,000"
WHEN 2300.CLM.claim_amount > 75000
THEN REJECT "Claim over $75,000 auto-rejected";

-- Level 4 — Condition Overlap: range 40000–60000 overlaps with > 50000
RULE mid_range_review "Review claims in $40k–$60k range"
WHEN 2300.CLM.claim_amount BETWEEN 40000 AND 60000
THEN REQUIRE_REVIEW "Mid-range claim needs manual review";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP B: Provider Tenure Rules  (Levels 2, 3, 4)
-- ──────────────────────────────────────────────────────────────────────────────

RULE new_provider_90 "Flag new providers (< 90 days)"
WHEN 2010.NM1.provider_tenure_days < 90
THEN FLAG_FRAUD "Provider credentialed fewer than 90 days";

-- Level 2 — Subsumption: < 30 implies < 90, same action
RULE very_new_provider_30 "Flag very new providers (< 30 days)"
WHEN 2010.NM1.provider_tenure_days < 30
THEN FLAG_FRAUD "Provider credentialed fewer than 30 days";

-- Level 3 — Shadowed: < 60 implies < 90, but different action
RULE new_provider_reject "Reject providers under 60 days"
WHEN 2010.NM1.provider_tenure_days < 60
THEN REJECT "Provider too new — reject claim";

-- Level 4 — Overlap: range 0–120 overlaps with < 90
RULE provider_probation "Review providers in probation window (0–120 days)"
WHEN 2010.NM1.provider_tenure_days BETWEEN 0 AND 120
THEN REQUIRE_REVIEW "Provider in probation window";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP C: Place-of-Service Rules  (Levels 1, 3)
-- ──────────────────────────────────────────────────────────────────────────────

RULE er_visit_flag "Flag ER claims"
WHEN 2400.SV1.place_of_service = "23"
THEN FLAG_FRAUD "Emergency room visit flagged for review";

-- Level 1 — Exact Duplicate
RULE er_visit_flag_copy "Duplicate ER flag"
WHEN 2400.SV1.place_of_service = "23"
THEN FLAG_FRAUD "Emergency room visit flagged for review";

-- Level 3 — Shadowed: same condition, different action
RULE er_visit_reject "Reject ER claims outright"
WHEN 2400.SV1.place_of_service = "23"
THEN REJECT "ER claims auto-rejected by policy";


-- ──────────────────────────────────────────────────────────────────────────────
-- GROUP D: Compound Condition Rules  (Levels 2, 4)
-- ──────────────────────────────────────────────────────────────────────────────

RULE high_amount_new_provider "High amount + new provider combo"
WHEN 2300.CLM.claim_amount > 50000 AND 2010.NM1.provider_tenure_days < 90
THEN [FLAG_FRAUD "High amount from new provider", RISK_SCORE 85];

-- Level 2 — Subsumption: the AND rule is more specific than high_amount_50k alone
-- (already covered by high_amount_50k above — its condition implies high_amount_50k)

-- Level 4 — Overlap: shares claim_amount field with mid_range_review and
-- shares provider_tenure_days field with provider_probation
RULE moderate_amount_newer_provider "Moderate amount + newer provider"
WHEN 2300.CLM.claim_amount > 30000 AND 2010.NM1.provider_tenure_days < 120
THEN REQUIRE_REVIEW "Moderate amount from newer provider";
