#!/bin/bash
# Automated DSL Rule Parser Test Script

API_URL="http://localhost:8080/api/parse-rule"
VALID_RULES_FILE="$(dirname "$0")/../fixtures/rules/valid_rules.dsl"

echo "=========================================="
echo "JSON Claims Integrity DSL Parser - Automated Tests"
echo "=========================================="
echo ""

# Check if server is running
if ! curl -s http://localhost:8080/api/health > /dev/null 2>&1; then
    echo "ERROR: Haskell backend not running on port 8080"
    echo "Start it with: cd haskell_engine && stack run"
    exit 1
fi

echo "✓ Backend server is running"
echo ""

# Extract individual rules from the file
# Rules are separated by blank lines and start with "RULE"

PASSED=0
FAILED=0
TOTAL=0

# Read the file and split by "RULE" keyword
current_rule=""
rule_name=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comment lines
    if [[ "$line" =~ ^-- ]]; then
        continue
    fi

    # Check if this is a new rule
    if [[ "$line" =~ ^RULE[[:space:]] ]]; then
        # If we have a previous rule, test it
        if [[ -n "$current_rule" ]]; then
            TOTAL=$((TOTAL + 1))
            echo "Test $TOTAL: $rule_name"

            # Send to API
            response=$(curl -s -X POST "$API_URL" \
                -H "Content-Type: application/json" \
                -d "{\"ruleText\": $(echo "$current_rule" | jq -Rs .)}")

            success=$(echo "$response" | jq -r '.success // false')

            if [[ "$success" == "true" ]]; then
                echo "  ✓ PASSED"
                PASSED=$((PASSED + 1))
            else
                echo "  ✗ FAILED"
                error=$(echo "$response" | jq -r '.error // "Unknown error"')
                echo "  Error: $error"
                FAILED=$((FAILED + 1))
            fi
            echo ""
        fi

        # Start new rule
        rule_name=$(echo "$line" | sed -E 's/^RULE[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/\1/')
        current_rule="$line"
    else
        # Append to current rule
        if [[ -n "$current_rule" ]]; then
            current_rule="$current_rule"$'\n'"$line"
        fi
    fi
done < "$VALID_RULES_FILE"

# Test the last rule
if [[ -n "$current_rule" ]]; then
    TOTAL=$((TOTAL + 1))
    echo "Test $TOTAL: $rule_name"

    response=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"ruleText\": $(echo "$current_rule" | jq -Rs .)}")

    success=$(echo "$response" | jq -r '.success // false')

    if [[ "$success" == "true" ]]; then
        echo "  ✓ PASSED"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ FAILED"
        error=$(echo "$response" | jq -r '.error // "Unknown error"')
        echo "  Error: $error"
        FAILED=$((FAILED + 1))
    fi
    echo ""
fi

echo "=========================================="
echo "RESULTS"
echo "=========================================="
echo "Total:  $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "✓ ALL TESTS PASSED"
    exit 0
else
    echo "✗ SOME TESTS FAILED"
    exit 1
fi
