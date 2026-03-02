#!/bin/bash
# Automated DSL Rule Parser Test Script - Faulty Rules
# These rules SHOULD fail to parse

API_URL="http://localhost:8080/api/parse-rule"
FAULTY_RULES_FILE="$(dirname "$0")/../fixtures/rules/faulty_rules.dsl"

echo "=========================================="
echo "JSON Claims Integrity DSL Parser - Faulty Rule Tests"
echo "=========================================="
echo "These rules should FAIL to parse"
echo ""

# Check if server is running
if ! curl -s http://localhost:8080/api/health > /dev/null 2>&1; then
    echo "ERROR: Haskell backend not running on port 8080"
    echo "Start it with: cd haskell_engine && stack run"
    exit 1
fi

echo "✓ Backend server is running"
echo ""

CORRECT_FAILURES=0
UNEXPECTED_PASSES=0
TOTAL=0

current_rule=""
rule_name=""
expected_fault=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Capture fault description from comments
    if [[ "$line" =~ ^--[[:space:]]*FAULT[[:space:]]*([0-9]+):[[:space:]]*(.*) ]]; then
        expected_fault="${BASH_REMATCH[2]}"
        continue
    fi

    # Skip other comment lines
    if [[ "$line" =~ ^-- ]]; then
        continue
    fi

    # Check if this is a new rule
    if [[ "$line" =~ ^RULE[[:space:]] ]]; then
        # If we have a previous rule, test it
        if [[ -n "$current_rule" ]]; then
            TOTAL=$((TOTAL + 1))
            echo "Test $TOTAL: $rule_name"
            echo "  Expected fault: $expected_fault"

            # Send to API
            response=$(curl -s -X POST "$API_URL" \
                -H "Content-Type: application/json" \
                -d "{\"ruleText\": $(echo "$current_rule" | jq -Rs .)}")

            success=$(echo "$response" | jq -r '.success // false')

            if [[ "$success" == "false" ]]; then
                echo "  ✓ CORRECTLY FAILED"
                error=$(echo "$response" | jq -r '.error // "Unknown error"' | head -c 80)
                echo "  Error: $error..."
                CORRECT_FAILURES=$((CORRECT_FAILURES + 1))
            else
                echo "  ✗ UNEXPECTED PASS (should have failed!)"
                UNEXPECTED_PASSES=$((UNEXPECTED_PASSES + 1))
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
done < "$FAULTY_RULES_FILE"

# Test the last rule
if [[ -n "$current_rule" ]]; then
    TOTAL=$((TOTAL + 1))
    echo "Test $TOTAL: $rule_name"
    echo "  Expected fault: $expected_fault"

    response=$(curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"ruleText\": $(echo "$current_rule" | jq -Rs .)}")

    success=$(echo "$response" | jq -r '.success // false')

    if [[ "$success" == "false" ]]; then
        echo "  ✓ CORRECTLY FAILED"
        error=$(echo "$response" | jq -r '.error // "Unknown error"' | head -c 80)
        echo "  Error: $error..."
        CORRECT_FAILURES=$((CORRECT_FAILURES + 1))
    else
        echo "  ✗ UNEXPECTED PASS (should have failed!)"
        UNEXPECTED_PASSES=$((UNEXPECTED_PASSES + 1))
    fi
    echo ""
fi

echo "=========================================="
echo "RESULTS"
echo "=========================================="
echo "Total:              $TOTAL"
echo "Correctly Failed:   $CORRECT_FAILURES"
echo "Unexpected Passes:  $UNEXPECTED_PASSES"
echo ""

if [[ $UNEXPECTED_PASSES -eq 0 ]]; then
    echo "✓ ALL FAULTY RULES CORRECTLY REJECTED"
    exit 0
else
    echo "✗ SOME FAULTY RULES INCORRECTLY PASSED"
    exit 1
fi
