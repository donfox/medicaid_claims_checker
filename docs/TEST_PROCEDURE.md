# Test Procedure — JSON Claims Integrity

## Prerequisites

| Dependency | Check command |
|------------|---------------|
| Haskell (Stack/Cabal) | `cabal --version` |
| Elixir / Phoenix | `elixir --version && mix --version` |
| PostgreSQL | `pg_isready` |
| curl | `curl --version` |
| jq | `jq --version` |
| Python 3 | `python3 --version` |

---

## Phase 1 — Unit Tests (offline, no servers required)  


### 1A. Haskell DSL Engine (hspec)

```bash
cd haskell_engine
cabal test --test-show-details=direct
```

**Expected:** 54 tests across 7 groups, all passing:

| Group | Tests | Covers |
|-------|-------|--------|
| DSL Parser | 18 | Parsing operators, segments, loops, LET bindings, helpers |
| PolicyCombiner | 7 | ML+DSL merge, risk thresholds (T_low 0.35, T_high 0.80, T_siu 0.93) |
| MLClient Parser | 6 | Contract version, risk score extraction, required fields |
| Evaluation Request Contract | 4 | Version validation, required fields, tenant_id |
| Claim Scenarios — BA Rules | 10 | CLM001–CLM010 expected decisions and risk levels |
| Claim Scenarios — DSL + ML | 5 | CLM011–CLM015 combined pipeline |
| Helper Functions | 4 | is_weekend, is_high_amount, in_list |

**Pass criteria:** `54 examples, 0 failures`

### 1B. Phoenix / Elixir (ExUnit)

```bash
cd phoenix_web
mix test
```

**Expected tests:**

| File | Tests | Covers |
|------|-------|--------|
| error_html_test.exs | 2 | 404/500 HTML rendering |
| error_json_test.exs | 2 | 404/500 JSON rendering |
| payload_builder_test.exs | 5+ | Batch/single payload structure, tenant defaults, DSL normalization |

**Pass criteria:** `0 failures`

---

## Phase 2 — Start Services

```bash
# From project root — starts both backend (8080) and frontend (4000)
./start.sh -f
```

Or individually:

```bash
# Terminal 1 — Haskell engine
cd haskell_engine && cabal run x12-fraud-dsl-exe

# Terminal 2 — Phoenix web
cd phoenix_web && mix phx.server
```

### Verify both services are healthy

```bash
curl -s http://localhost:8080/api/health | jq .
# Expected: {"status": "healthy"}

curl -s http://localhost:4000/api/health
# Expected: 200 OK
```

---

## Phase 3 — Integration Tests (Haskell API)

### 3A. Valid rule parsing

```bash
cd phoenix_web
bash test/scripts/run_tests.sh
```

Posts each rule from `valid_rules.dsl` to `/api/parse-rule`.

**Pass criteria:** `Passed: 10, Failed: 0`

### 3B. Faulty rule rejection

```bash
bash test/scripts/run_faulty_tests.sh
```

Posts each intentionally broken rule from `faulty_rules.dsl` and confirms the parser rejects it.

**Pass criteria:** All rules correctly fail (exit 0).

### 3C. Full integration suite

```bash
bash test/scripts/test_integration.sh
```

End-to-end test covering:

| Step | Endpoint | Assertion |
|------|----------|-----------|
| Health check | GET /api/health | status = "healthy" |
| Compile 4 rules | POST /api/compile-rules | success = true, compiledCount = 4 |
| Batch evaluate 10 claims | POST /api/batch-evaluate | Per-claim risk and matchedRules (see table below) |
| Extended batch (10 rules × 6 claims) | POST /api/batch-evaluate | LET bindings, helpers, compound conditions |

**Expected batch results (CLM001–CLM010):**

| Claim | Matched Rules | Risk Level | Decision |
|-------|---------------|------------|----------|
| CLM001 | 0 | LowRisk | APPROVE |
| CLM002 | 1 (high_value_review) | LowRisk | REQUIRE_REVIEW |
| CLM003 | 1 (weekend_office_visit) | LowRisk | REQUIRE_REVIEW |
| CLM004 | 1 (inpatient_mismatch) | CriticalRisk | REJECT |
| CLM005 | 2 (extreme_amount + high_value) | CriticalRisk | FLAG_FRAUD |
| CLM006 | 2 (high_value + weekend) | LowRisk | REQUIRE_REVIEW |
| CLM007 | 0 | LowRisk | APPROVE |
| CLM008 | 0 | LowRisk | APPROVE |
| CLM009 | 2 (high_value + inpatient) | CriticalRisk | REJECT |
| CLM010 | 3 (extreme + high_value + inpatient) | CriticalRisk | REJECT |

**Extended batch results (CLM016–CLM021):**

| Claim | Matched Rules | Risk Level |
|-------|---------------|------------|
| CLM016 | 1 (suspicious_dx) | CriticalRisk |
| CLM017 | 1 (weekend_service_date) | LowRisk |
| CLM018 | 1 (invalid_npi_prefix) | CriticalRisk |
| CLM019 | 2 (half_million + high_value) | CriticalRisk |
| CLM020 | 1 (unapproved_state) | LowRisk |
| CLM021 | 1 (medium_value_range via LET) | LowRisk |

**Pass criteria:** All checks green, exit 0.

---

## Phase 4 — Manual API Smoke Tests

Run these individually to verify key endpoints beyond the scripted tests.

### 4A. Single claim evaluation

```bash
curl -s -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d @- <<'EOF' | jq .
{
  "contract_version": "1.0",
  "request_id": "SMOKE-001",
  "claim_id": "SMOKE-CLM-001",
  "tenant_id": "smoke_test",
  "rulesText": "RULE high_amount\n  DESCRIPTION \"Flag high amounts\"\n  WHEN 2300.CLM.claim_amount > 50000\n  THEN FLAG_FRAUD\nEND",
  "document": {
    "2300": { "CLM": { "claim_amount": 75000, "facility_type": "Outpatient" } },
    "2400": { "SV1": { "procedure_code": "99213" } }
  }
}
EOF
```

**Expected:** `matchedRules` contains `high_amount`, decision includes `FLAG_FRAUD`.

### 4B. Redundancy check

```bash
curl -s -X POST http://localhost:8080/api/check-redundancy \
  -H "Content-Type: application/json" \
  -d "{\"rulesText\": \"$(cat phoenix_web/test/fixtures/rules/redundancy_test_rules.dsl | sed 's/"/\\"/g' | tr '\n' '\\' | sed 's/\\/\\n/g')\"}" | jq .
```

**Expected:** Detects exact duplicates, subsumption, shadowed rules, and overlapping conditions per the groupings below.

#### Redundancy Groupings (12 rules, 4 groups)

**Group A — High-Amount Rules** (`2300.CLM.claim_amount`)

| Rule | Condition | Action | Redundant With | Level |
|------|-----------|--------|----------------|-------|
| high_amount_50k | > 50000 | FLAG_FRAUD | — (baseline) | — |
| high_amount_50k_dup | > 50000 | FLAG_FRAUD | high_amount_50k | 1 — Exact Duplicate |
| extreme_amount_100k | > 100000 | FLAG_FRAUD | high_amount_50k (> 100k implies > 50k) | 2 — Subsumption |
| high_amount_reject | > 75000 | REJECT | high_amount_50k (> 75k implies > 50k, different action) | 3 — Shadowed |
| mid_range_review | BETWEEN 40000 AND 60000 | REQUIRE_REVIEW | high_amount_50k (50k–60k overlap) | 4 — Condition Overlap |

**Group B — Provider Tenure Rules** (`2010.NM1.provider_tenure_days`)

| Rule | Condition | Action | Redundant With | Level |
|------|-----------|--------|----------------|-------|
| new_provider_90 | < 90 | FLAG_FRAUD | — (baseline) | — |
| very_new_provider_30 | < 30 | FLAG_FRAUD | new_provider_90 (< 30 implies < 90) | 2 — Subsumption |
| new_provider_reject | < 60 | REJECT | new_provider_90 (< 60 implies < 90, different action) | 3 — Shadowed |
| provider_probation | BETWEEN 0 AND 120 | REQUIRE_REVIEW | new_provider_90 (0–90 overlap) | 4 — Condition Overlap |

**Group C — Place-of-Service Rules** (`2400.SV1.place_of_service`)

| Rule | Condition | Action | Redundant With | Level |
|------|-----------|--------|----------------|-------|
| er_visit_flag | = "23" | FLAG_FRAUD | — (baseline) | — |
| er_visit_flag_copy | = "23" | FLAG_FRAUD | er_visit_flag | 1 — Exact Duplicate |
| er_visit_reject | = "23" | REJECT | er_visit_flag (same condition, different action) | 3 — Shadowed |

**Group D — Compound Condition Rules** (multi-field)

| Rule | Condition | Action | Redundant With | Level |
|------|-----------|--------|----------------|-------|
| high_amount_new_provider | amount > 50k AND tenure < 90 | FLAG_FRAUD + RISK_SCORE 85 | high_amount_50k (AND is stricter → subsumed) | 2 — Subsumption |
| moderate_amount_newer_provider | amount > 30k AND tenure < 120 | REQUIRE_REVIEW | mid_range_review (amount overlap), provider_probation (tenure overlap) | 4 — Condition Overlap |

#### Cross-Group Overlaps

| Rule Pair | Shared Field | Overlap Region |
|-----------|-------------|----------------|
| high_amount_new_provider ↔ high_amount_50k | claim_amount > 50000 | Compound AND implies the single condition |
| moderate_amount_newer_provider ↔ mid_range_review | claim_amount 40k–60k vs > 30k | 40k–60k range falls within > 30k |
| moderate_amount_newer_provider ↔ provider_probation | tenure 0–120 vs < 120 | Nearly identical tenure range |

### 4C. Parse-only (no caching)

```bash
curl -s -X POST http://localhost:8080/api/parse-rule \
  -H "Content-Type: application/json" \
  -d '{"ruleText": "RULE test_parse\n  DESCRIPTION \"Parse only\"\n  WHEN claim_amount > 100\n  THEN REQUIRE_REVIEW\nEND"}' | jq .
```

**Expected:** `{"success": true, ...}` with parsed AST summary.

---

## Phase 5 — UI Functional Tests (browser)

Open `http://localhost:4000/rules` and verify the following:

### 5A. Rule Catalogue display

- [ ] Catalogue panel renders with correct count (e.g., "Rule Catalogue (17)")
- [ ] Each entry shows the correct type badge: blue=BA Rule, indigo=Default Rule, purple=ML Model
- [ ] Collapsible `<details>` section opens/closes

### 5B. Default Rule (read-only)

- [ ] Click any Default Rule (e.g., "ImpossibleDates")
- [ ] Form shows "Default Rule — read-only system rule" banner
- [ ] Text area has gray background, is not editable
- [ ] Only a "Dismiss" button appears (no Save)
- [ ] SELECTED badge appears on the clicked entry

### 5C. BA Rule (editable)

- [ ] Click a BA Rule (e.g., "HighValueReview")
- [ ] DSL text loads into the editor and is editable
- [ ] "Save Edits" button is visible
- [ ] Edit the text and click Save → success feedback
- [ ] SELECTED badge appears on the clicked entry

### 5D. ML Model entry

- [ ] Click "Fraud ML Model"
- [ ] Displays as read-only with purple ML Model badge
- [ ] No edit capability

### 5E. Create new BA Rule

- [ ] Enter a new rule name in the Rule Name field
- [ ] Enter valid DSL text
- [ ] Click Save → new entry appears in catalogue
- [ ] Count increments (e.g., 17 → 18)

### 5F. Rule Catalogue page

- [ ] Navigate to `http://localhost:4000/catalogue`
- [ ] Page renders the catalogue list view

---

## Phase 6 — End-to-End Workflow

This validates the full pipeline: load rules → submit claims → verify outcomes.

### Step 1: Compile rules via API

```bash
curl -s -X POST http://localhost:8080/api/compile-rules \
  -H "Content-Type: application/json" \
  -d @phoenix_web/test/fixtures/batches/batch_request.json | jq '{success, compiledCount}'
```

**Expected:** `{"success": true, "compiledCount": 4}`

### Step 2: Batch evaluate claims

```bash
curl -s -X POST http://localhost:8080/api/batch-evaluate \
  -H "Content-Type: application/json" \
  -d @phoenix_web/test/fixtures/batches/batch_request.json | jq '.batchResults[] | {claim_id, matchedRulesCount: (.matchedRules | length), overallRisk, decision: .decision.status}'
```

**Expected:** Matches the CLM001–CLM010 table from Phase 3.

### Step 3: Verify with clean claim

```bash
curl -s -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d '{
    "contract_version": "1.0",
    "request_id": "E2E-CLEAN",
    "claim_id": "E2E-CLM-CLEAN",
    "tenant_id": "e2e_test",
    "rulesText": "RULE simple_check\n  DESCRIPTION \"Flag large claims\"\n  WHEN 2300.CLM.claim_amount > 50000\n  THEN FLAG_FRAUD\nEND",
    "document": {
      "2300": {"CLM": {"claim_amount": 150, "facility_type": "Outpatient"}},
      "2400": {"SV1": {"procedure_code": "99213"}}
    }
  }' | jq '{matchedRules: (.matchedRules | length), decision: .decision.status}'
```

**Expected:** `{"matchedRules": 0, "decision": "APPROVE"}`

---

## Phase 7 — Negative / Edge-Case Tests

### 7A. Invalid contract version

```bash
curl -s -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d '{"contract_version": "2.0", "request_id": "NEG-001", "claim_id": "NEG-CLM", "tenant_id": "test", "rulesText": "RULE x DESCRIPTION \"x\" WHEN a > 1 THEN REJECT END", "document": {}}' | jq .
```

**Expected:** Error response rejecting unsupported contract version.

### 7B. Empty tenant ID

```bash
curl -s -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d '{"contract_version": "1.0", "request_id": "NEG-002", "claim_id": "NEG-CLM", "tenant_id": "", "rulesText": "RULE x DESCRIPTION \"x\" WHEN a > 1 THEN REJECT END", "document": {}}' | jq .
```

**Expected:** Error response rejecting empty tenant_id.

### 7C. Malformed DSL

```bash
curl -s -X POST http://localhost:8080/api/parse-rule \
  -H "Content-Type: application/json" \
  -d '{"ruleText": "RULE broken WHEN THEN END"}' | jq .
```

**Expected:** `{"success": false, ...}` with parse error details.

### 7D. Missing required fields

```bash
curl -s -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d '{"contract_version": "1.0"}' | jq .
```

**Expected:** Error listing missing required fields.

---

## Summary Checklist

| Phase | Description | Method | Pass Criteria |
|-------|-------------|--------|---------------|
| 1A | Haskell unit tests | `cabal test` | 54 examples, 0 failures |
| 1B | Phoenix unit tests | `mix test` | 0 failures |
| 2 | Service startup | `./start.sh -f` | Both health endpoints return OK |
| 3A | Valid rule parsing | `run_tests.sh` | 10/10 passed |
| 3B | Faulty rule rejection | `run_faulty_tests.sh` | All rules correctly rejected |
| 3C | Full integration | `test_integration.sh` | All checks pass, exit 0 |
| 4 | Manual API smoke | curl commands | Expected responses match |
| 5 | UI functional | Browser checklist | All checkboxes ticked |
| 6 | End-to-end workflow | curl pipeline | Compile → evaluate → correct results |
| 7 | Negative/edge cases | curl commands | Proper error responses |
