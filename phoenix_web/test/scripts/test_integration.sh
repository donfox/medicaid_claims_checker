#!/usr/bin/env bash
# ---------------------------------------------------------------
# Integration test: JSON Claims Integrity DSL Engine
# Requires the Haskell engine running on port 8080.
# Start it with:  ./start.sh --backend   (or ./start.sh)
# ---------------------------------------------------------------
set -euo pipefail

BASE_URL="${HASKELL_ENGINE_URL:-http://localhost:8080}"
FIXTURE="$(dirname "$0")/../fixtures/batches/batch_request.json"
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

bold "=== JSON Claims Integrity — API Integration Tests ==="
echo "  Engine: $BASE_URL"
echo ""

# ---------------------------------------------------------------
# 1. Health check
# ---------------------------------------------------------------
bold "--- Health Check ---"
HEALTH=$(curl -sf "$BASE_URL/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
HS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
check "engine is healthy" "$HS" "healthy"
echo ""

# ---------------------------------------------------------------
# 2. Compile-rules preflight
# ---------------------------------------------------------------
bold "--- Compile Rules ---"
RULES_TEXT=$(python3 -c "import json; print(json.load(open('$FIXTURE'))['rulesText'])")
COMPILE_RESP=$(curl -sf -X POST "$BASE_URL/api/compile-rules" \
  -H "Content-Type: application/json" \
  -d "{\"rulesText\": $(python3 -c "import json; print(json.dumps('$RULES_TEXT'))")}" \
  2>/dev/null || echo '{"success":false}')
COMPILE_OK=$(echo "$COMPILE_RESP"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('success',False)).lower())")
COMPILED_N=$(echo "$COMPILE_RESP"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('compiledCount',0))")
check "compile succeeded"     "$COMPILE_OK" "true"
check "4 rules compiled"      "$COMPILED_N" "4"
echo ""

# ---------------------------------------------------------------
# 3. Batch evaluate — 10 mock claims
# ---------------------------------------------------------------
bold "--- Batch Evaluate (10 mock claims) ---"
BATCH_RESP=$(curl -sf -X POST "$BASE_URL/api/batch-evaluate" \
  -H "Content-Type: application/json" \
  -d @"$FIXTURE" 2>/dev/null || echo '{}')

total_claims=$(echo "$BATCH_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalClaims',0))")
check "totalClaims = 10" "$total_claims" "10"

# Helper: matched-rule count for claim at index N
matched_for() {
  local idx="$1"
  echo "$BATCH_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('batchResults', [])
item = next((r for r in results if r['claimIndex'] == $idx), {})
print(item.get('report', {}).get('matchedRules', -1))
"
}

# Helper: overallRisk for claim at index N
risk_for() {
  local idx="$1"
  echo "$BATCH_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('batchResults', [])
item = next((r for r in results if r['claimIndex'] == $idx), {})
print(item.get('report', {}).get('overallRisk', '?'))
"
}

check "CLM001 valid: 0 rules matched"                   "$(matched_for 0)" "0"
check "CLM001 valid: LowRisk"                           "$(risk_for   0)" "LowRisk"

check "CLM002 high value: 1 rule matched"               "$(matched_for 1)" "1"
check "CLM002 high value: LowRisk (REQUIRE_REVIEW)"     "$(risk_for   1)" "LowRisk"

check "CLM003 weekend office: 1 rule matched"           "$(matched_for 2)" "1"

check "CLM004 inpatient mismatch: 1 rule matched"       "$(matched_for 3)" "1"
check "CLM004 inpatient mismatch: CriticalRisk"         "$(risk_for   3)" "CriticalRisk"

check "CLM005 extreme amount: 2 rules matched"          "$(matched_for 4)" "2"
check "CLM005 extreme amount: CriticalRisk"             "$(risk_for   4)" "CriticalRisk"

check "CLM006 high value + weekend: 2 rules matched"    "$(matched_for 5)" "2"

check "CLM007 wrong POS: 0 rules matched"               "$(matched_for 6)" "0"

check "CLM008 inpatient low amount: 0 rules matched"    "$(matched_for 7)" "0"

check "CLM009 compound: 2 rules matched"                "$(matched_for 8)" "2"
check "CLM009 compound: CriticalRisk"                   "$(risk_for   8)" "CriticalRisk"

check "CLM010 triple violation: 3 rules matched"        "$(matched_for 9)" "3"
check "CLM010 triple violation: CriticalRisk"           "$(risk_for   9)" "CriticalRisk"

echo ""

# ---------------------------------------------------------------
# 4. Extended batch — 10 rules × 6 new claim types (CLM016-021)
# ---------------------------------------------------------------
EXT_FIXTURE="$(dirname "$0")/../fixtures/batches/batch_request_extended.json"

bold "--- Compile Extended Rules (10 rules) ---"
# Build a {"rulesText": "..."} payload by extracting from the fixture
EXT_COMPILE_PAYLOAD=$(mktemp)
python3 -c "
import json
rules = json.load(open('$EXT_FIXTURE'))['rulesText']
json.dump({'rulesText': rules}, open('$EXT_COMPILE_PAYLOAD', 'w'))
"
EXT_COMPILE=$(curl -sf -X POST "$BASE_URL/api/compile-rules" \
  -H "Content-Type: application/json" \
  -d @"$EXT_COMPILE_PAYLOAD" 2>/dev/null || echo '{"success":false}')
rm -f "$EXT_COMPILE_PAYLOAD"
EXT_OK=$(echo "$EXT_COMPILE" | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('success',False)).lower())")
EXT_N=$(echo  "$EXT_COMPILE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('compiledCount',0))")
check "extended compile succeeded"  "$EXT_OK" "true"
check "10 rules compiled"           "$EXT_N"  "10"
echo ""

bold "--- Extended Batch Evaluate (6 new claim types, CLM016-021) ---"
EXT_RESP=$(curl -sf -X POST "$BASE_URL/api/batch-evaluate" \
  -H "Content-Type: application/json" \
  -d @"$EXT_FIXTURE" 2>/dev/null || echo '{}')

ext_total=$(echo "$EXT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalClaims',0))")
check "totalClaims = 6" "$ext_total" "6"

ext_matched() {
  local idx="$1"
  echo "$EXT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
item = next((r for r in d.get('batchResults',[]) if r['claimIndex']==$idx), {})
print(item.get('report',{}).get('matchedRules',-1))
"
}

ext_risk() {
  local idx="$1"
  echo "$EXT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
item = next((r for r in d.get('batchResults',[]) if r['claimIndex']==$idx), {})
print(item.get('report',{}).get('overallRisk','?'))
"
}

# CLM016: suspicious dx Z76.89 → FLAG_FRAUD
check "CLM016 suspicious_dx: 1 rule matched"      "$(ext_matched 0)" "1"
check "CLM016 suspicious_dx: CriticalRisk"        "$(ext_risk    0)" "CriticalRisk"

# CLM017: weekend service_date (actual Sat, DOW field=TUE) → weekend_service_date
check "CLM017 weekend_service_date: 1 rule matched" "$(ext_matched 1)" "1"
check "CLM017 weekend_service_date: LowRisk"        "$(ext_risk    1)" "LowRisk"

# CLM018: NPI starts with 0 → invalid_npi_prefix FLAG_FRAUD
check "CLM018 invalid_npi_prefix: 1 rule matched"  "$(ext_matched 2)" "1"
check "CLM018 invalid_npi_prefix: CriticalRisk"    "$(ext_risk    2)" "CriticalRisk"

# CLM019: $750k → half_million_composite [FLAG_FRAUD, RISK_SCORE 85] + high_value_review
check "CLM019 half_million + high_value: 2 matched" "$(ext_matched 3)" "2"
check "CLM019 composite FLAG_FRAUD: CriticalRisk"   "$(ext_risk    3)" "CriticalRisk"

# CLM020: MT state → unapproved_state REQUIRE_REVIEW
check "CLM020 unapproved_state: 1 rule matched"    "$(ext_matched 4)" "1"
check "CLM020 unapproved_state: LowRisk"           "$(ext_risk    4)" "LowRisk"

# CLM021: $35k → medium_value_range (LET binding) REQUIRE_REVIEW
check "CLM021 medium_value_range: 1 rule matched"  "$(ext_matched 5)" "1"
check "CLM021 medium_value_range: LowRisk"         "$(ext_risk    5)" "LowRisk"

echo ""
bold "--- Results ---"
green "  Passed: $PASS"
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL" || true
echo ""
[ "$FAIL" -eq 0 ] && green "All integration tests passed." || { red "Some tests FAILED."; exit 1; }
