# Business Rules Syntax Guide

## Purpose

This guide explains how to write Medicaid Claims Checker business rules using the project’s domain-specific language (DSL). It is intended for business analysts and implementers who need to author, review, or troubleshoot rules.

## Rule Block Styles

The engine currently accepts two rule styles.

### Style A — Recommended

```text
RULE <rule_name>
DESCRIPTION "<description>"
WHEN <predicate>
THEN <action>
END
```

### Style B — Legacy shorthand

```text
RULE <rule_name> "<description>"
WHEN <predicate>
THEN <action>;
```

## Rule Keywords

| Keyword | Meaning |
|---|---|
| `RULE` | Starts a rule definition |
| `rule_name` | Unique identifier using letters, numbers, and underscores |
| `DESCRIPTION` | Human-readable description in quotes |
| `WHEN` | Introduces the condition to test |
| `predicate` | Logical expression that evaluates to true, false, or unknown when data is missing (see [Missing data](#missing-data)) |
| `THEN` | Introduces the action to take when the predicate matches |
| `action` | The outcome triggered by the rule |
| `END` | Ends the rule block |

## Comments

Use comments for plain-English notes:

```text
-- Check for unusually high claim amounts
```

## Predicates and Conditions

### Comparison operators

```text
field = value
field != value
field > value
field < value
field >= value
field <= value
```

Meaning:

- `=` equals
- `!=` not equals
- `>` greater than
- `<` less than
- `>=` greater than or equal
- `<=` less than or equal

### Null checks

```text
field IS NULL
field IS NOT NULL
```

Use these to check whether a field is missing or present.

### Boolean literals

```text
TRUE
FALSE
```

Typical uses:

- `TRUE` always matches, which can be useful for testing or forced-review rules.
- `FALSE` never matches, which can be useful when temporarily disabling a rule without deleting it.

Example:

```text
RULE disabled_check "Temporarily disabled"
WHEN FALSE
THEN FLAG_FRAUD "Should never fire"
END
```

### Logical operators

```text
predicate1 AND predicate2
predicate1 OR predicate2
NOT predicate
```

### Missing data

A condition that depends on data the claim does not have is **unknown**, not true or false. Data counts as missing when:

- the field is absent or null;
- a number is expected but the field holds text;
- a date is expected but cannot be read;
- a collection (`EXISTS`, `FORALL`) is absent or empty.

A rule fires only when its condition is definitely true, so **missing data never makes a rule match by itself**.

`NOT`, `AND` and `OR` keep this rule:

| Condition | Amount 500, status `"paid"` | No amount, status `"paid"` |
|---|---|---|
| `amount <= 10000` | match | no match |
| `NOT amount > 10000` | match | no match |
| `amount > 10000 OR status = "paid"` | match | match — the `OR` is true because of `status` |
| `NOT (amount > 10000 AND status = "denied")` | match | match — the `AND` is false because of `status` |

To act on missing data, say so explicitly:

```text
provider.npi IS NULL
COUNT(service_lines) = 0
```

`IS NULL`, `IS NOT NULL` and `COUNT` always give a definite answer. `COUNT` treats a missing collection as zero items.

When a rule does not match because of missing data, the claim's results list it under **Not checked — missing or unusable data**, and the claim is not called clean or included in the **Clean** filter. In the evaluation report, the rule's result has `resultUndecided: true` and the details `Rule did not match: missing or unusable data`, and `undecidedRules` counts such rules. A `LET` binding whose field is missing counts the same way.

### Range checks

```text
field BETWEEN low AND high
```

This range is inclusive: `low <= field <= high`.

Example:

```text
financial.claim_amount BETWEEN 1000 AND 50000
```

### Domain predicates

```text
claim.has_diagnosis "code"
claim.has_procedure "code"
```

These search standard claim arrays without requiring explicit `EXISTS` logic:

- `diagnosis_codes[*].code`
- `procedure_codes[*].code`
- `service_lines[*].procedure_code`

### Quantifiers

```text
EXISTS loop.segment WHERE predicate
FORALL loop.segment WHERE predicate
COUNT(loop.segment) > n
```

Use these forms when you need to inspect repeated structures such as service lines.

- `EXISTS` matches when at least one item definitely matches.
- `FORALL` matches when every item definitely matches. An item that is missing the field makes `FORALL` unknown, not true.
- Over an absent or empty collection, both are unknown, so neither `EXISTS`, `FORALL`, `NOT EXISTS` nor `NOT FORALL` matches. Use `COUNT(path) = 0` to find claims with no items.

### Named quantifier variables

You can bind an element to a variable using `IN`. This is especially useful for nested logic because the outer variable stays accessible inside the inner expression.

```text
EXISTS x IN path WHERE x.field = "value"
FORALL x IN path WHERE x.field > 100
EXISTS x IN lines WHERE x.code = "99213"
  AND EXISTS y IN lines WHERE y.code = "99214"
```

The unnamed form still works:

```text
EXISTS path WHERE ...
```

However, nested unnamed quantifiers lose access to the outer element because the evaluation context shifts.

### Text operators

```text
field CONTAINS "text"
field MATCHES "regex"
```

- `CONTAINS` is true when the field's text includes the given substring.
- `MATCHES` uses POSIX extended regular expressions. It searches anywhere in the value unless the pattern is anchored: `^` and `$` refer to the start and end of the whole field value.
- An invalid pattern is reported as a parse error when the rule is saved, rather than silently never matching.
- A missing field never matches either operator, and `NOT` does not change that (see [Missing data](#missing-data)).

Example:

```text
NOT (provider.npi MATCHES "^[0-9]{10}$")
```

This matches an NPI that is present but malformed. It does not match a claim with no NPI (see [Missing data](#missing-data)). To catch both:

```text
provider.npi IS NULL OR NOT (provider.npi MATCHES "^[0-9]{10}$")
```

### String helper operations

```text
starts_with(field, "pre")
in_list(field, ["A", "B"])
```

Notes:

- `starts_with` checks for a text prefix.
- `in_list` checks membership in a list.
- A misspelled helper name, or a helper called with the wrong number of arguments, is reported as an error when the rule is saved (for example `Unknown helper function: is_weekand`).

## Field References

### Claim JSON structure

Claims are represented as hierarchical JSON paths. Some older examples still use loop and segment labels as field-key conventions.

Common legacy loop labels:

- `2300` — Claim Information
- `2400` — Service Line
- `2010` — Provider or Patient Name
- `2320` — Other Subscriber Information

Common legacy segment labels:

- `CLM` — Claim segment
- `SV1` — Professional Service
- `DTP` — Date or Time Period
- `HI` — Health Care Diagnosis Code
- `NM1` — Name

### Reference formats

```text
field_name
CLM.claim_amount
2300.CLM.claim_amount
claim.billing_provider.address.zip
```

These correspond to:

- simple field reference
- segment + field
- loop + segment + field
- any deeper path: each part names the next level of the claim JSON

### Reusable bindings with `LET`

Use `LET` lines between `DESCRIPTION` and `WHEN` when the same field reference will be reused.

```text
RULE high_value_er
DESCRIPTION "ER high-value claim"
LET amount = 2300.CLM.claim_amount
LET place = 2400.SV1.place_of_service
WHEN place = "23" AND amount > 5000
THEN REQUIRE_REVIEW "ER high amount"
END
```

## Values

### String values

```text
"text in quotes"
```

### Numeric values

```text
100
250.50
10000.00
```

### Date values as strings

```text
"2026-01-24"
"20260124"
```

### Field-to-field comparisons

The right-hand side of a comparison can be another field reference instead of a literal.

```text
2400.DTP.service_date > 2300.DTP.admission_date
CLM.billed_amount > CLM.allowed_amount
```

## Actions

### `FLAG_FRAUD`

Flags a claim as potentially fraudulent with a reason.

```text
FLAG_FRAUD "Reason for flagging"
```

### `REJECT`

Rejects the claim with a reason.

```text
REJECT "Reason for rejection"
```

### `REQUIRE_REVIEW`

Flags the claim for analyst review (overall risk HighRisk) with a reviewer note.

```text
REQUIRE_REVIEW "Note for reviewer"
```

### `RISK_SCORE`

Assigns a numeric risk score from `0` to `100`. A score of `70` or more flags the claim for analyst review (overall risk HighRisk); a lower score is recorded with the rule but does not flag the claim by itself.

```text
RISK_SCORE 75
```

### `APPROVE`

Approves the claim with a reason. This is the least severe action. It does **not** elevate risk and does **not** override a `REJECT` triggered by another rule.

```text
APPROVE "Reason for approval"
```

### Multiple actions

You can combine actions with brackets and commas.

```text
[FLAG_FRAUD "High amount", RISK_SCORE 85, REQUIRE_REVIEW "Urgent"]
```

## Complete Examples

### Example 1 — High claim amount

```text
RULE high_claim_amount "Flag unusually high claim amounts"
WHEN 2300.CLM.claim_amount > 50000.0
THEN FLAG_FRAUD "Claim amount exceeds $50,000 threshold";
```

### Example 2 — Missing required field

```text
RULE missing_diagnosis "Reject claims without diagnosis code"
WHEN 2300.HI.diagnosis_code IS NULL
THEN REJECT "Diagnosis code is required for all claims";
```

### Example 3 — Complex pattern with `AND`

```text
RULE excessive_daily_charges "Multiple high-value services same day"
WHEN COUNT(2400) > 10 
     AND FORALL 2400 WHERE 2400.SV1.line_charge > 500.0
THEN [FLAG_FRAUD "Excessive billing pattern", RISK_SCORE 80];
```

### Example 4 — Unbundling detection

```text
RULE unbundling_check "Detect unbundled E&M codes"
WHEN EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99213"
     AND EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99214"
THEN FLAG_FRAUD "Possible unbundling of E&M services";
```

### Example 5 — Age-inappropriate service

```text
RULE age_check "Service not appropriate for patient age"
WHEN 2010.NM1.patient_age < 18
     AND 2400.SV1.procedure_code = "99385"
THEN REQUIRE_REVIEW "Adult preventive service for minor";
```

### Example 6 — Multiple conditions with `OR`

```text
RULE suspicious_location "Service in unusual location"
WHEN 2400.SV1.place_of_service = "99"
     OR 2400.SV1.place_of_service IS NULL
THEN [REQUIRE_REVIEW "Verify service location", RISK_SCORE 50];
```

## Best Practices

### 1. Use descriptive rule names

```text
✓ GOOD: high_claim_amount
✗ BAD:  rule1
```

### 2. Write clear descriptions

```text
✓ GOOD: "Flag claims with amounts exceeding $50,000"
✗ BAD:  "Check amount"
```

### 3. Use realistic thresholds

```text
✓ GOOD: claim_amount > 50000.0
✗ BAD:  claim_amount > 1000000.0
```

### 4. Combine related checks when that improves readability

```text
✓ GOOD:
RULE comprehensive_check "Multiple red flags"
WHEN amount > 50000.0 AND COUNT(2400) > 20
THEN [FLAG_FRAUD "Multiple issues", RISK_SCORE 90];

✗ BAD: Creating 10 separate rules for related checks
```

### 5. Use risk scores consistently

- `0–69` — recorded with the matched rule; does not flag the claim by itself
- `70–100` — flags the claim for analyst review (overall risk HighRisk)

To flag a claim for review regardless of score, add `REQUIRE_REVIEW`. `FLAG_FRAUD` and `REJECT` make the overall risk CriticalRisk.

## Common Patterns

### Pattern — Range check using `OR`

```text
RULE amount_range "Amount outside normal range"
WHEN 2300.CLM.claim_amount < 10.0
     OR 2300.CLM.claim_amount > 100000.0
THEN REQUIRE_REVIEW "Unusual claim amount";
```

### Pattern — Range check using `BETWEEN`

```text
RULE normal_amount
DESCRIPTION "Approve claims in normal range"
WHEN financial.claim_amount BETWEEN 100 AND 10000
THEN APPROVE "Claim amount within normal range"
END
```

### Pattern — Diagnosis-based check

```text
RULE diabetes_review
DESCRIPTION "Review claims with diabetes diagnosis"
WHEN claim.has_diagnosis "E11.9"
     AND financial.claim_amount > 5000
THEN REQUIRE_REVIEW "High-cost diabetes claim"
END
```

### Pattern — Cross-line correlation with named quantifiers

```text
RULE unbundling_named
DESCRIPTION "Detect unbundled E&M codes using named variables"
WHEN EXISTS x IN service_lines WHERE x.procedure_code = "99213"
     AND EXISTS y IN service_lines WHERE y.procedure_code = "99214"
THEN FLAG_FRAUD "Possible unbundling of E&M services"
END
```

### Pattern — Duplicate detection

```text
RULE duplicate_claims "Multiple claims same day"
WHEN COUNT(2300) > 3
THEN FLAG_FRAUD "Possible duplicate submission";
```

### Pattern — Cross-field validation

```text
RULE date_consistency "Service date after submission"
WHEN 2400.DTP.service_date > 2300.DTP.submission_date
THEN REJECT "Service date cannot be after submission";
```

### Pattern — Provider validation

```text
RULE provider_status "Check provider eligibility"
WHEN 2010.NM1.provider_status = "suspended"
     OR 2010.NM1.provider_status = "terminated"
THEN REJECT "Provider is not eligible to submit claims";
```

## Testing Your Rules

1. Start with simple rules.
2. Test them before adding complexity.
3. Use the web interface to validate syntax.
4. Test against sample claims data.
5. Review false positives and adjust thresholds.

## Troubleshooting

### Parse errors

Check for:

- missing semicolons in legacy shorthand rules
- unbalanced quotes
- misspelled keywords such as `RULE`, `WHEN`, or `THEN`
- unmatched parentheses
- misspelled helper names or the wrong number of helper arguments

### Runtime errors

Check for:

- field names that do not match your claim JSON structure. A misspelled field is treated as missing data, so the rule does not match and is listed as not checked.
- numeric comparisons written as strings
- incorrect loop IDs such as `2300` or `2400`

If a rule never fires, check that the claims actually contain every field the rule uses, and that numbers and dates are in a readable form. Missing or unreadable data makes a condition unknown, and an unknown condition never fires (see [Missing data](#missing-data)).

## Need Help?

Contact the project owner for:

- custom field mappings
- new operators or helper functions
- performance issues
- questions about claim JSON structure
