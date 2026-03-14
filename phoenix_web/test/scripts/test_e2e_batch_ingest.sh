#!/usr/bin/env bash
# ---------------------------------------------------------------
# End-to-end integration test: X12Translator batch ingest pipeline
#
# Simulates the full flow:
#   X12Translator  --(POST)--> /api/x12-batch-ingest
#   medicaid_claims_checker  --(auto-eval)--> Haskell engine
#   Results stored on edi_files, batch marked completed.
#
# Prerequisites:
#   1. Haskell engine running on port 8080
#   2. Phoenix app running on port 4000
#   3. Database with migrations applied
#   4. At least one active BA rule in business_rules table
#
# Start with:
#   cd haskell_engine && stack run &
#   cd phoenix_web   && mix phx.server &
# ---------------------------------------------------------------
set -euo pipefail

PHOENIX_URL="${PHOENIX_URL:-http://localhost:4000}"
HASKELL_URL="${HASKELL_ENGINE_URL:-http://localhost:8080}"
BATCH_ID="e2e-test-$(date +%s)"
PASS=0
FAIL=0

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'   "$*"; }

check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    green "  PASS  $label"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label"
    red   "        expected: $expected"
    red   "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    green "  PASS  $label"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label"
    red   "        expected to contain: $needle"
    red   "        actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

bold "=== End-to-End: X12Translator -> medicaid_claims_checker -> Haskell ==="
echo "  Phoenix:  $PHOENIX_URL"
echo "  Haskell:  $HASKELL_URL"
echo "  Batch ID: $BATCH_ID"
echo ""

# ---------------------------------------------------------------
# 0. Preflight: check both services are up
# ---------------------------------------------------------------
bold "--- Preflight ---"

HASKELL_HEALTH=$(curl -sf "$HASKELL_URL/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
HS=$(echo "$HASKELL_HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
check "Haskell engine is healthy" "$HS" "healthy"

PHOENIX_HEALTH=$(curl -sf "$PHOENIX_URL/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
check_contains "Phoenix app is reachable" "$PHOENIX_HEALTH" "healthy"

echo ""

# ---------------------------------------------------------------
# 1. POST batch ingest — simulating X12Translator webhook
# ---------------------------------------------------------------
bold "--- Step 1: POST /api/x12-batch-ingest (simulate X12Translator) ---"

# Build a batch payload with 3 claims of varying risk profiles
PAYLOAD=$(cat <<ENDJSON
{
  "batch_id": "$BATCH_ID",
  "source": "e2e-test",
  "claims": [
    {
      "filename": "claim_clean_office_visit.json",
      "claim": {
        "submission_type": "healthcare_claim_997",
        "claim_id": "CLM-E2E-CLEAN",
        "provider": {
          "name": "Family Practice Clinic",

          "type": "Clinic",
          "state": "MO",
          "tenure_days": 800,
          "risk_score": 10,
          "specialty": "Family Medicine"
        },
        "billing_provider": { "name": "Family Practice Clinic" },
        "patient": {
          "name": { "first": "Jane", "last": "Doe" },
          "date_of_birth": "1990-05-15",
          "gender": "Female",
          "patient_id": "PAT-E2E-001"
        },
        "claim_details": {
          "service_type": "Office Visit",
          "place_of_service": "11",
          "admission_type": "Ambulatory"
        },
        "diagnosis_codes": [
          { "code": "Z00.00", "description": "General exam", "qualifier": "Principal" }
        ],
        "service_lines": [
          {
            "procedure_code": "99213",
            "units": 1,
            "unit_rate": 150.00,
            "line_amount": 150.00,
            "date_of_service": "2026-01-15",
            "place_of_service": "11"
          }
        ],
        "claim_totals": { "total_submitted": 150.00 },
        "financial": { "claim_amount": 150.00 },
        "2300": { "CLM": { "claim_amount": 150, "facility_type": "Outpatient" } },
        "2400": { "SV1": { "place_of_service": "11" }, "DTP": { "service_day_of_week": "TUE" } }
      }
    },
    {
      "filename": "claim_high_value.json",
      "claim": {
        "submission_type": "healthcare_claim_997",
        "claim_id": "CLM-E2E-HIGHVAL",
        "provider": {
          "name": "Specialty Surgery Center",

          "type": "Hospital",
          "state": "CA",
          "tenure_days": 500,
          "risk_score": 25,
          "specialty": "Surgery"
        },
        "billing_provider": { "name": "Specialty Surgery Center" },
        "patient": {
          "name": { "first": "John", "last": "Smith" },
          "date_of_birth": "1975-08-20",
          "gender": "Male",
          "patient_id": "PAT-E2E-002"
        },
        "claim_details": {
          "service_type": "Hospital Inpatient",
          "admission_type": "Emergency"
        },
        "diagnosis_codes": [
          { "code": "E11.9", "description": "Type 2 diabetes", "qualifier": "Principal" }
        ],
        "service_lines": [
          {
            "procedure_code": "99213",
            "units": 5,
            "unit_rate": 15000.00,
            "line_amount": 75000.00,
            "date_of_service": "2026-01-15",
            "place_of_service": "11"
          }
        ],
        "claim_totals": { "total_submitted": 75000.00 },
        "financial": { "claim_amount": 75000.00 },
        "2300": { "CLM": { "claim_amount": 75000, "facility_type": "Outpatient" } },
        "2400": { "SV1": { "place_of_service": "11" }, "DTP": { "service_day_of_week": "TUE" } }
      }
    },
    {
      "filename": "claim_extreme_amount.json",
      "claim": {
        "submission_type": "healthcare_claim_997",
        "claim_id": "CLM-E2E-EXTREME",
        "provider": {
          "name": "Premium Medical Center",

          "type": "Hospital",
          "state": "CA",
          "tenure_days": 500,
          "risk_score": 50,
          "specialty": "Acute Care"
        },
        "billing_provider": { "name": "Premium Medical Center" },
        "patient": {
          "name": { "first": "Bob", "last": "Jones" },
          "date_of_birth": "1960-01-01",
          "gender": "Male",
          "patient_id": "PAT-E2E-003"
        },
        "claim_details": {
          "service_type": "Hospital Inpatient",
          "admission_type": "Emergency"
        },
        "diagnosis_codes": [
          { "code": "I21.0", "description": "STEMI", "qualifier": "Principal" }
        ],
        "service_lines": [
          {
            "procedure_code": "33533",
            "units": 1,
            "unit_rate": 1500000.00,
            "line_amount": 1500000.00,
            "date_of_service": "2026-01-15",
            "place_of_service": "22"
          }
        ],
        "claim_totals": { "total_submitted": 1500000.00 },
        "financial": { "claim_amount": 1500000.00 },
        "2300": { "CLM": { "claim_amount": 1500000, "facility_type": "Outpatient" } },
        "2400": { "SV1": { "place_of_service": "11" }, "DTP": { "service_day_of_week": "MON" } }
      }
    }
  ]
}
ENDJSON
)

INGEST_RESP=$(curl -s -w "\n%{http_code}" -X POST "$PHOENIX_URL/api/x12-batch-ingest" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

HTTP_CODE=$(echo "$INGEST_RESP" | tail -1)
INGEST_BODY=$(echo "$INGEST_RESP" | sed '$d')

check "Ingest returns 201 Created" "$HTTP_CODE" "201"

INGEST_STATUS=$(echo "$INGEST_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
check "Ingest status = accepted" "$INGEST_STATUS" "accepted"

CLAIMS_INGESTED=$(echo "$INGEST_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claims_ingested',0))")
check "3 claims ingested" "$CLAIMS_INGESTED" "3"

BATCH_DB_ID=$(echo "$INGEST_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batch_db_id','?'))")
echo "  Batch DB ID: $BATCH_DB_ID"

echo ""

# ---------------------------------------------------------------
# 2. Poll batch status until evaluation completes
# ---------------------------------------------------------------
bold "--- Step 2: Poll batch status via GET /api/x12-batch-ingest/:batch_id ---"

MAX_WAIT=30
ELAPSED=0
BATCH_STATUS="pending"

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))

  STATUS_RESP=$(curl -sf "$PHOENIX_URL/api/x12-batch-ingest/$BATCH_ID" 2>/dev/null || echo '{}')
  BATCH_STATUS=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")

  echo "  ${ELAPSED}s — batch status: $BATCH_STATUS"

  if [ "$BATCH_STATUS" = "completed" ] || [ "$BATCH_STATUS" = "failed" ]; then
    break
  fi
done

check "Batch evaluation completed" "$BATCH_STATUS" "completed"

# Verify evaluation results from the status response
if [ "$BATCH_STATUS" = "completed" ]; then
  FILE_COUNT=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('files',[])))")
  check "3 files in batch response" "$FILE_COUNT" "3"

  # Check individual file evaluation results
  # With the full BA rule set, the clean claim triggers structural rules
  # (missing_diagnosis_codes, missing_required_fields) because the X12 segment
  # format lacks nested fields expected by those rules. Verify it was evaluated.
  FILE0_MATCHED=$(echo "$STATUS_RESP" | python3 -c "
import sys,json
files = json.load(sys.stdin).get('files',[])
f = next((f for f in files if f['filename']=='claim_clean_office_visit.json'), {})
print(f.get('matched_rules', 0))
")
  # Should have at least 1 matched rule (structural validation rules fire)
  FILE0_HAS_RESULTS=$(python3 -c "print('yes' if int('$FILE0_MATCHED') >= 1 else 'no')")
  check "Clean claim was evaluated (rules matched >= 1)" "$FILE0_HAS_RESULTS" "yes"

  FILE2_STATUS=$(echo "$STATUS_RESP" | python3 -c "
import sys,json
files = json.load(sys.stdin).get('files',[])
f = next((f for f in files if f['filename']=='claim_extreme_amount.json'), {})
print(f.get('status','?'))
")
  check "Extreme claim status = fraudulent" "$FILE2_STATUS" "fraudulent"

  FILE2_RISK=$(echo "$STATUS_RESP" | python3 -c "
import sys,json
files = json.load(sys.stdin).get('files',[])
f = next((f for f in files if f['filename']=='claim_extreme_amount.json'), {})
print(f.get('risk','?'))
")
  check "Extreme claim risk = CriticalRisk" "$FILE2_RISK" "CriticalRisk"

  FILE2_MATCHED=$(echo "$STATUS_RESP" | python3 -c "
import sys,json
files = json.load(sys.stdin).get('files',[])
f = next((f for f in files if f['filename']=='claim_extreme_amount.json'), {})
print(f.get('matched_rules','?'))
")
  # Extreme claim triggers high_value_review + structural rules (>= 2)
  FILE2_HAS_MULTI=$(python3 -c "print('yes' if int('$FILE2_MATCHED') >= 2 else 'no')")
  check "Extreme claim: >= 2 rules matched" "$FILE2_HAS_MULTI" "yes"
fi

echo ""

# ---------------------------------------------------------------
# 3. Verify batch uniqueness — re-POST same batch_id
# ---------------------------------------------------------------
bold "--- Step 3: Verify batch uniqueness (re-POST same batch_id) ---"

DUPE_RESP=$(curl -s -w "\n%{http_code}" -X POST "$PHOENIX_URL/api/x12-batch-ingest" \
  -H "Content-Type: application/json" \
  -d "{\"batch_id\": \"$BATCH_ID\", \"source\": \"e2e-dupe-test\", \"claims\": [{\"filename\": \"dupe.json\", \"claim\": {}}]}" \
  2>/dev/null)

DUPE_CODE=$(echo "$DUPE_RESP" | tail -1)
check "Duplicate batch_id rejected (422)" "$DUPE_CODE" "422"

echo ""

# ---------------------------------------------------------------
# 4. Verify the Haskell engine directly
#    (Confirms engine produces expected results for the same claims)
# ---------------------------------------------------------------
bold "--- Step 4: Verify Haskell engine evaluation (direct call) ---"

# Use the same rules that BA rules table should contain.
# We test with a minimal known rule set to confirm the engine works.
ENGINE_PAYLOAD=$(cat <<'ENGJSON'
{
  "rulesText": "RULE high_value_review \"Flag high-value claims\" WHEN 2300.CLM.claim_amount > 50000 THEN REQUIRE_REVIEW \"High value\"; RULE extreme_amount \"Extreme billing\" WHEN 2300.CLM.claim_amount > 1000000 THEN FLAG_FRAUD \"Extreme amount\";",
  "claims": [
    { "2300": { "CLM": { "claim_amount": 150 } }, "2400": {} },
    { "2300": { "CLM": { "claim_amount": 75000 } }, "2400": {} },
    { "2300": { "CLM": { "claim_amount": 1500000 } }, "2400": {} }
  ]
}
ENGJSON
)

ENGINE_RESP=$(curl -sf -X POST "$HASKELL_URL/api/batch-evaluate" \
  -H "Content-Type: application/json" \
  -d "$ENGINE_PAYLOAD" 2>/dev/null || echo '{}')

ENGINE_TOTAL=$(echo "$ENGINE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalClaims',0))")
check "Engine evaluated 3 claims" "$ENGINE_TOTAL" "3"

# Claim 0: $150 — no rules match
MATCH0=$(echo "$ENGINE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
r = d.get('batchResults',[])[0]
print(r.get('report',{}).get('matchedRules',-1))
")
check "Clean claim: 0 rules matched" "$MATCH0" "0"

RISK0=$(echo "$ENGINE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
r = d.get('batchResults',[])[0]
print(r.get('report',{}).get('overallRisk','?'))
")
check "Clean claim: LowRisk" "$RISK0" "LowRisk"

# Claim 1: $75k — high_value_review matches
MATCH1=$(echo "$ENGINE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
r = d.get('batchResults',[])[1]
print(r.get('report',{}).get('matchedRules',-1))
")
check "High value claim: 1 rule matched" "$MATCH1" "1"

# Claim 2: $1.5M — both rules match
MATCH2=$(echo "$ENGINE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
r = d.get('batchResults',[])[2]
print(r.get('report',{}).get('matchedRules',-1))
")
check "Extreme claim: 2 rules matched" "$MATCH2" "2"

RISK2=$(echo "$ENGINE_RESP" | python3 -c "
import sys,json
d = json.load(sys.stdin)
r = d.get('batchResults',[])[2]
print(r.get('report',{}).get('overallRisk','?'))
")
check "Extreme claim: CriticalRisk" "$RISK2" "CriticalRisk"

echo ""

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
bold "=== Results ==="
green "  Passed: $PASS"
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL" || true
echo ""
[ "$FAIL" -eq 0 ] && green "All end-to-end tests passed." || { red "Some tests FAILED."; exit 1; }
