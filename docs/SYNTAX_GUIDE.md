# Business Rules Syntax Guide

## Purpose

This guide explains how to write Medicaid Claims Checker business rules using the project’s domain-specific language (DSL). It is intended for business analysts (BAs) and implementers who need to author, review, or troubleshoot rules.

## Rule Block Styles

The engine accepts two rule styles, and the seeded rules use both.

### Style A — with `DESCRIPTION` and `END`

```text
RULE <rule_name>
DESCRIPTION "<description>"
WHEN <predicate>
THEN <action>
END
```

### Style B — shorthand, ending in a semicolon

```text
RULE <rule_name> "<description>"
WHEN <predicate>
THEN <action>;
```

The description may also go on its own line after `RULE <rule_name>`.

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

A comment runs from `--` to the end of the line. Comments and line breaks may go anywhere a space may: inside parentheses, after `WHERE`, between list items or helper arguments.

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

`>`, `<`, `>=` and `<=` always compare numbers. `=` and `!=` compare numbers only when the value on the right is a number written in the rule (`financial.claim_amount = 500`); against a string or another field they compare the text, so `220` and `220.00` are different. To compare two amount fields, use `<` and `>` (see [Field-to-field comparisons](#field-to-field-comparisons)).

### Null checks

```text
field IS NULL
field IS NOT NULL
```

Use these to check whether a field is missing or present. A field is null when it is absent or JSON `null`; a field that holds an object (such as `provider`) or a list (such as `service_lines`) is not null.

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

When a rule does not match because of missing data, the claim's results list it under **Not checked — missing or unusable data**, and the claim is not called clean or included in the **Clean** filter. In the evaluation report, the rule's result has `resultUndecided: true` and the details name what was missing, for example `Rule did not match: missing or unusable data (financial.claim_amount missing; service_lines missing or empty)`, and `undecidedRules` counts such rules. A field can be named as missing (absent or null), not a number, not a valid date, or not a single value; a field inside `EXISTS line IN service_lines` is named `service_lines[].field`. A `LET` binding whose field is missing counts the same way.

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
- `service_lines[*].procedure_code`

A code written as a JSON number (`99213`) matches the same code in quotes (`"99213"`).

### Quantifiers

```text
EXISTS line IN service_lines WHERE predicate
FORALL line IN service_lines WHERE predicate
COUNT(service_lines) > n
```

Use these forms when you need to inspect repeated structures such as service lines. The name after `EXISTS`/`FORALL` (here `line`) stands for one item inside the `WHERE`: `line.procedure_code`, `line.charge_amount`. A path with an index, such as `service_lines.0.date_of_service`, reads only that one item, here the first service line.

#### How far a `WHERE` reaches

The condition after `WHERE` runs to the end of the rule's condition, or to the closing parenthesis around the quantifier. Everything joined with `AND` or `OR` after `WHERE` is checked inside each item:

```text
-- Wrong: claim_amount is looked up inside each service line, where it is
-- missing, so the rule never fires and every claim is "not checked".
EXISTS service_lines WHERE procedure_code = "99285" AND financial.claim_amount > 10000

-- Right: parentheses end the quantifier.
(EXISTS service_lines WHERE procedure_code = "99285") AND financial.claim_amount > 10000
```

With a named variable (`EXISTS line IN service_lines WHERE line.procedure_code = "99285" AND financial.claim_amount > 10000`) the claim-level field is still found, but it is checked once per line and the whole condition is unknown when the claim has no lines. Put claim-level conditions outside the quantifier, in parentheses, unless they really belong to each item.

- `EXISTS` matches when at least one item definitely matches.
- `FORALL` matches when every item definitely matches. An item that is missing the field makes `FORALL` unknown, not true.
- Over an absent or empty collection, both are unknown, so neither `EXISTS`, `FORALL`, `NOT EXISTS` nor `NOT FORALL` matches. Use `COUNT(path) = 0` to find claims with no items.

### Named quantifier variables

You can bind an element to a variable using `IN`. This is especially useful for nested logic because the outer variable stays accessible inside the inner expression: in its fields, and as the start of an inner `EXISTS`, `FORALL` or `COUNT` path.

```text
EXISTS x IN path WHERE x.field = "value"
FORALL x IN path WHERE x.field > 100
EXISTS x IN lines WHERE x.code = "99213"
  AND EXISTS y IN lines WHERE y.code = "99214"
EXISTS line IN service_lines WHERE EXISTS m IN line.modifiers WHERE m.code = "25"
EXISTS line IN service_lines WHERE COUNT(line.modifiers) > 2
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

### Helper functions

```text
starts_with(provider.taxonomy, "207")
in_list(claim_details.place_of_service, ["11", "22"])
is_weekend(line.date_of_service)
```

| Helper | True when |
|---|---|
| `starts_with(field, "text")` | the field's text begins with `"text"` |
| `in_list(field, ["A", "B"])` | the field's text is one of the listed values |
| `is_weekend(date)` | the date is a Saturday or Sunday |
| `is_future_date(date)` | the date is after today (the date where the engine runs, not UTC) |
| `is_date_before(date, "1900-01-01")` | the first date is earlier than the second |
| `is_age_valid(date_of_birth, min, max)` | the age today, in whole years, is from `min` to `max` inclusive |
| `is_npi_format(npi)` | the value is exactly 10 digits |
| `is_valid_npi(npi)` | the value is 10 digits and passes the NPI (Luhn-10) check digit |
| `is_high_amount(amount, threshold)` | the amount is greater than the threshold |

Notes:

- An argument can be a field, a `LET` name, a quantifier variable's field such as `line.date_of_service`, or a literal.
- Dates are read in the formats listed under [Date values as strings](#date-values-as-strings). A field that is missing, or not a readable date or number, makes the helper unknown, not false (see [Missing data](#missing-data)).
- Helper names are not case-sensitive.
- A misspelled helper name, or a helper called with the wrong number of arguments, is reported as an error when the rule is saved (for example `Unknown helper function: is_weekand`).

## Field References

### Claim JSON structure

Rules read the claim after it is converted from the X12 837 file, not the raw file. Each part of a path names the next level of the converted claim JSON.

Main sections:

- `claim_id` — claim identifier
- `financial.claim_amount`, `claim_totals.total_charges` — amounts
- `claim_totals.service_line_total` — the sum of the service lines' `charge_amount`, worked out by the app just before evaluation (for X12 and JSON claims alike) and added in exact cents. Empty when the claim has no lines or any line's charge is missing or not a number
- `claim_details` — `place_of_service`, `facility_type_code`, `frequency_code` (1 original, 7 replacement, 8 void); on 837I claims also `statement_from_date`, `statement_to_date` (the statement period) and `admission_date`
- `provider`, `billing_provider` — `npi`, `name`, `taxonomy`, `tax_id`; `billing_provider.address` has `street`, `city`, `state`, `zip`
- `provider.tenure_days` — how many days the provider has been credentialed (the two new-provider rules use it). Only JSON claims carry it; X12 conversion leaves it empty, so on an X12 claim a rule using it is not checked
- `rendering_provider` — `npi`, `taxonomy_code`, `last_name`, `first_name`
- `patient` — `date_of_birth`, `gender`, `name.first`, `name.last`; the subscriber's details unless the file has a separate patient loop (a dependant)
- `subscriber` — `member_id`, `date_of_birth`, `relationship_code`, `group_number`
- `payer` — `name`, `payer_id`
- `authorization.authorization_number`
- `diagnosis_codes` — list; each has `code` and `qualifier` (`ABK` principal, `ABF` other, `ABJ` admitting, `ABN` external cause, `APR` reason for visit; `BK`, `BF`, ... are the retired ICD-9 forms). Only diagnoses are listed here
- `other_codes` — list, 837I only: the other codes in the claim's HI segments, each with `code` and `qualifier` (`BG` condition, `BH` occurrence, `BI` occurrence span, `BE` value, `BBR`/`BBQ` inpatient procedure)
- `service_lines` — list; each has `procedure_code`, `charge_amount`, `units`, `date_of_service`, `place_of_service`, `line_number`, `diagnosis_pointer`, `revenue_code`

A line dated as a range has its start in `date_of_service` and its end in `date_of_service_end` (empty for a single date). A line with no date of its own, common on 837I claims, takes the claim's statement period. An element left blank in the file is empty, so `IS NULL` finds it.

The list above covers the fields rules usually need. The full list, including middle names, the subscriber's address, dental `tooth_info` and the envelope sections (`submitter`, `receiver`, `interchange`, `functional_group`), is in `phoenix_web/lib/medicaid_claims_checker/claims/rule_schema_validator.ex`.

The Rules page checks every field a rule uses against that list, reading the rule the way the engine does: a quantifier variable stands for its list's items, a `LET` name for its path, and inside an unnamed `EXISTS`/`FORALL` a field is looked up in each item (so a claim-level field there is flagged, with a reminder to close the quantifier with parentheses). Strings and `--` comments are ignored. A rule naming a field that no converted claim has is saved as a draft and cannot be activated; the message suggests the field to use where there is one.

Each rule is saved on its own: the Rules page refuses a text that holds more than one rule.

The name after `RULE` must differ from every other rule's (capitals ignored, inactive rules included), because results and Jobs History are labelled with it. The Rules page refuses a rule whose name another rule already uses and names that rule. This is separate from the name the Rules page lists, which you type in its own box.

### X12 loop-style paths are not fields

Older examples used X12 loop and segment labels, such as `2300.CLM.claim_amount` (loop 2300, segment CLM). Those name where a value sits in the raw file. Converted claims have no such keys, so these rules never fire. Use the converted field instead:

| Loop-style path | Use |
|---|---|
| `2300.CLM.claim_amount` | `financial.claim_amount` |
| `2300.HI.diagnosis_code` | `diagnosis_codes` (e.g. `COUNT(diagnosis_codes) = 0`) |
| `2400.SV1.procedure_code` | `line.procedure_code` inside `EXISTS line IN service_lines` |
| `2400.SV1.line_charge` | `line.charge_amount` |
| `2400.SV1.place_of_service` | `line.place_of_service` |
| `2400.DTP.service_date` | `line.date_of_service` |

### Reference formats

```text
claim_id
financial.claim_amount
billing_provider.address.zip
EXISTS line IN service_lines WHERE line.charge_amount > 500
service_lines.0.procedure_code
```

These correspond to:

- top-level field
- section + field
- deeper path
- any item of a list (`FORALL` for every item, `COUNT(...)` for how many)
- one list item by position (first service line only)

### Reusable bindings with `LET`

Use `LET` lines between `DESCRIPTION` and `WHEN` when the same field reference will be reused.

```text
RULE high_value_er
DESCRIPTION "ER high-value claim"
LET amount = financial.claim_amount
LET place = claim_details.place_of_service
WHEN place = "23" AND amount > 5000
THEN REQUIRE_REVIEW "ER high amount"
END
```

A `LET` name stands for its field path, so it behaves exactly as if the path were written out: when the field is missing, `place IS NULL` is true and a comparison on `place` is not checked, naming `claim_details.place_of_service` as missing. A `LET` always refers to the whole claim, even inside `EXISTS` or `FORALL`. It may name an object or a list (`LET lines = service_lines`, then `COUNT(lines)`) or an earlier `LET`.

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
"2026-01-24T10:30:00"
```

### Field-to-field comparisons

The right-hand side of a comparison can be another field reference instead of a literal.

```text
financial.claim_amount > claim_totals.total_charges
EXISTS line IN service_lines WHERE line.charge_amount > financial.claim_amount
```

Between two fields, `=` and `!=` compare text. To find two amounts that differ, write it as a number comparison:

```text
financial.claim_amount > claim_totals.service_line_total
  OR financial.claim_amount < claim_totals.service_line_total
```

## Actions

An action is a recommendation, not a decision. It sets the claim's overall risk level and records the reason for the BA; it never changes the claim's status, and nothing is paid, denied or approved by a rule.

### `FLAG_FRAUD`

Recommends referral for investigation, with a reason. Makes the overall risk CriticalRisk.

```text
FLAG_FRAUD "Reason for flagging"
```

### `REJECT`

Recommends rejecting the claim, with a reason. Makes the overall risk CriticalRisk.

```text
REJECT "Reason for rejection"
```

### `REQUIRE_REVIEW`

Asks for BA review (overall risk HighRisk), with a reviewer note.

```text
REQUIRE_REVIEW "Note for reviewer"
```

### `RISK_SCORE`

Assigns a numeric risk score from `0` to `100`. A score of `70` or more flags the claim for BA review (overall risk HighRisk); a lower score is recorded with the rule but does not flag the claim by itself.

```text
RISK_SCORE 75
```

### `APPROVE`

Records that the claim looks acceptable, with a reason. This is the least severe action. It does **not** raise the risk level and does **not** cancel a `REJECT` or `FLAG_FRAUD` from another rule.

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
WHEN financial.claim_amount > 50000.0
THEN FLAG_FRAUD "Claim amount exceeds $50,000 threshold";
```

### Example 2 — Missing required field

```text
RULE missing_diagnosis "Reject claims without diagnosis code"
WHEN COUNT(diagnosis_codes) = 0
THEN REJECT "Diagnosis code is required for all claims";
```

### Example 3 — Complex pattern with `AND`

```text
RULE excessive_daily_charges "Multiple high-value services same day"
WHEN COUNT(service_lines) > 10
     AND FORALL line IN service_lines WHERE line.charge_amount > 500.0
THEN [FLAG_FRAUD "Excessive billing pattern", RISK_SCORE 80];
```

### Example 4 — Age-inappropriate service

```text
RULE age_check "Service not appropriate for patient age"
WHEN NOT is_age_valid(patient.date_of_birth, 18, 130)
     AND EXISTS line IN service_lines WHERE line.procedure_code = "99385"
THEN REQUIRE_REVIEW "Adult preventive service for minor";
```

### Example 5 — Multiple conditions with `OR`

```text
RULE suspicious_location "Service in unusual location"
WHEN EXISTS line IN service_lines WHERE line.place_of_service = "99"
     OR claim_details.place_of_service IS NULL
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
✓ GOOD: financial.claim_amount > 50000.0
✗ BAD:  financial.claim_amount > 1000000.0
```

### 4. Combine related checks when that improves readability

```text
✓ GOOD:
RULE comprehensive_check "Multiple red flags"
WHEN financial.claim_amount > 50000.0 AND COUNT(service_lines) > 20
THEN [FLAG_FRAUD "Multiple issues", RISK_SCORE 90];

✗ BAD: Creating 10 separate rules for related checks
```

### 5. Use risk scores consistently

- `0–69` — recorded with the matched rule; does not flag the claim by itself
- `70–100` — flags the claim for BA review (overall risk HighRisk)

To flag a claim for review regardless of score, add `REQUIRE_REVIEW`. `FLAG_FRAUD` and `REJECT` make the overall risk CriticalRisk.

## Common Patterns

### Pattern — Range check using `OR`

```text
RULE amount_range "Amount outside normal range"
WHEN financial.claim_amount < 10.0
     OR financial.claim_amount > 100000.0
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

### Pattern — Two codes on the same claim (possible unbundling)

```text
RULE unbundling_named
DESCRIPTION "Detect unbundled E&M codes using named variables"
WHEN EXISTS x IN service_lines WHERE x.procedure_code = "99213"
     AND EXISTS y IN service_lines WHERE y.procedure_code = "99214"
THEN FLAG_FRAUD "Possible unbundling of E&M services"
END
```

### Pattern — Duplicate submissions

A rule sees one claim at a time, so it cannot detect duplicates. Ingestion refuses a file or claim that was already submitted and names the earlier batch in the upload message and Jobs History.

### Pattern — Any service line in the future

```text
RULE future_line "Any service line dated in the future"
WHEN EXISTS line IN service_lines WHERE is_future_date(line.date_of_service)
THEN REJECT "Service date is in the future";
```

### Pattern — Cross-field validation

```text
RULE line_exceeds_claim "A service line charges more than the whole claim"
WHEN EXISTS line IN service_lines WHERE line.charge_amount > financial.claim_amount
THEN REQUIRE_REVIEW "Line charge exceeds claim amount";
```

### Pattern — Provider validation

```text
RULE rendering_npi_check "Rendering provider NPI must pass its checksum"
WHEN rendering_provider.npi IS NOT NULL
     AND NOT is_valid_npi(rendering_provider.npi)
THEN REJECT "Rendering provider NPI fails Luhn-10 validation";
```

## Testing Your Rules

The Rules page (`/rules`) checks a rule's syntax as you type, and its fields when you save it. Run a rule against sample claims there, or upload the claim files in `mock_data/`. The P use cases in [FRONTEND_USE_CASES.md](FRONTEND_USE_CASES.md#p--rules-page) have rule files for the parser, the field check and redundancy warnings. Start simple, and adjust thresholds when a rule matches claims it shouldn't.

## Troubleshooting

### Parse errors

Check for:

- missing semicolons in legacy shorthand rules
- unbalanced quotes
- misspelled keywords such as `RULE`, `WHEN`, or `THEN`
- unmatched parentheses
- misspelled helper names or the wrong number of helper arguments
- values that could never be compared, which are refused when the rule is saved: a quoted number with `>`, `<`, `>=` or `<=` (write `amount > 10000`, not `amount > "10000"`), `BETWEEN` with anything but number bounds, a list after `=` or `!=` (use `in_list`), and an unquoted code in `claim.has_diagnosis` or `claim.has_procedure`
- numbers out of range: `RISK_SCORE` is 0 to 100, a `COUNT` is compared with 0 to 1,000,000
- more than 50 levels of nesting (parentheses, `NOT`, `EXISTS` and `FORALL` each count as a level)

### Runtime errors

Check for:

- field names that do not match your claim JSON structure. A misspelled field is treated as missing data, so the rule does not match and is listed as not checked. The Rules page catches most of these when the rule is saved.
- X12 loop-style paths such as `2300.CLM.claim_amount` (see [X12 loop-style paths are not fields](#x12-loop-style-paths-are-not-fields))

If a rule never fires, check that the claims actually contain every field the rule uses, and that numbers and dates are in a readable form. Missing or unreadable data makes a condition unknown, and an unknown condition never fires (see [Missing data](#missing-data)).
