# Manual Mock Validation Report

- **Date:** 2026-05-10
- **Scope:** Schema-drift fix validation and batch behavior confirmation
- **Environment:** Local Phoenix and Haskell services on macOS

## Summary

The verification cycle confirmed the following:

- The no-rules dataset behaved as expected: no rules matched and no fraud status was produced.
- The trigger dataset behaved as expected: all files matched and all were marked fraudulent.
- The active rule `MissingRequiredFields` is schema-valid after the latest validator and database text adjustments.

## Evidence

### Batch Results

#### No-rules dataset

- `NO_RULES_BATCH_ID`: `verify3-no_rules-1778443720`
- `NO_RULES_TOTAL`: `10`
- `NO_RULES_MATCHED_NONZERO`: `0`
- `NO_RULES_FRAUD`: `0`

#### Trigger dataset

- `TRIGGER_BATCH_ID`: `verify3-trigger_rules-1778443720`
- `TRIGGER_TOTAL`: `20`
- `TRIGGER_MATCHED_NONZERO`: `20`
- `TRIGGER_FRAUD`: `20`

### Rule Hit Breakdown for Trigger Batch

- `missing_required_fields`: `20`

### MissingRequiredFields Rule Status

- `MISSING_REQUIRED_FIELDS_ACTIVE`: `true`
- `MISSING_REQUIRED_FIELDS_SCHEMA_VALID`: `true`

## Commands Used

```bash
mix test test/medicaid_claims_checker/claims/rule_schema_validator_test.exs
mix run -e '<schema validation check for MissingRequiredFields>'
mix run -e '<manual no_rules + trigger_rules batch verification>'
```

## Notes

- Compile-time warnings were present in unrelated LiveView files and did not block execution.
- This report captures the latest `verify3` validation cycle.
- It can be used as QA sign-off evidence for the schema-drift stabilization work.
