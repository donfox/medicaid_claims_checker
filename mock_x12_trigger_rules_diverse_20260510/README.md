# Diverse Trigger Mock Data (2026-05-10)

This folder contains diversified X12 mock claims for rule-testing.

## Verified on Current Runtime

Batch run ID used for verification: `diverse2-1778445981`

### Proven diverse triggers

- `11_missing_required_only.x12`
  - Matched: `missing_required_fields`

- `12_nppes_only.x12`
  - Matched: `NPPESProviderLookup`

- `13_combo_missing_plus_nppes.x12`
  - Matched: `missing_required_fields`, `NPPESProviderLookup`
  - This is the multi-rule example.

### Additional scenario files (currently no match in this runtime)

These were crafted to target other BA rules, but did not fire with current rule-to-payload mapping behavior:

- `01_high_value_future.x12`
- `02_suspicious_low_charge.x12`
- `03_missing_diagnosis_codes.x12`
- `04_high_complexity_er.x12`
- `05_weekend_office_visit.x12`
- `06_patient_age_out_of_range.x12`
- `07_extreme_total_charges.x12`
- `08_invalid_npi_format.x12` (still triggers `NPPESProviderLookup`)
- `09_invalid_provider_npi.x12`
- `10_multi_rule_combo.x12` (still triggers `NPPESProviderLookup`)

## Notes

- The current runtime reliably demonstrates diversity using `missing_required_fields` and `NPPESProviderLookup`.
- To trigger a broader set of BA rules, those rules may need alignment with the exact claim JSON shape emitted by the X12 mapper.
