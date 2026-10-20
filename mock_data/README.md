# Mock data

Claims and rule files for trying the app by hand: upload a claim on the
home page (`http://localhost:4000/`) or paste a rule on the Rules page
(`/rules`). Automated tests don't load these files. Their expected results
are still checked, by `verify_x12_suite.exs` (see [Checking the samples](#checking-the-samples)).

```
mock_data/
  claims/
    clean/         no rule should match
    single_rule/   one file per active business rule, named after it
    multi_rule/    several rules at once
    nppes/         provider-status cases the NPPES check rejects (or accepts)
    redundancy/    for rules/redundancy_levels.dsl, not the business rules
  batches/         several claims in one file ({"claims": [...]})
  rules/
    redundancy_levels.dsl   overlapping rules for the redundancy checker
    examples.dsl            DSL features the business rules don't use
  manifest.json    expected result of every file
  generate.exs     writes claims/, batches/ and manifest.json
```

## What the claims contain

- **Layout.** Each claim uses the field layout the rules see, the output of
  `X12.SegmentMapper.normalize`. So a rule that works on a sample works on a
  converted 837. Diagnosis codes are written as an 837 carries them, without
  the dot (`E119`, not `E11.9`).
- **Providers are real.** Names, NPIs, primary taxonomies and practice
  addresses come from the NPI Registry (checked 2026-10-19). Service dates
  are in September 2026, when every one of these providers was active. Some
  providers are not real, and each claim's `sample_notes` says which: the
  deliberately invalid NPIs (`1234567`, `1003001578`, `1999999992`), and the
  deactivated (`1003002304`) and dropped (`1093462368`) NPIs, which have no
  public name or address.
- **Patients are synthetic.** So are member IDs, tax IDs and authorization
  numbers.
- **Fields that come only from JSON.** `provider.tenure_days` and
  `authorization.authorization_number` are never filled by X12 conversion.
  So NewProviderLargeSubmission and TaxonomyMismatchNewProvider can only be
  exercised with JSON claims like these.
- **`sample_notes`** in each claim explains what it should do. Rules ignore
  the field.

## Uploading a sample more than once

Phoenix refuses a file it has already received and a claim it has already
evaluated, naming the earlier submission. So each sample can be uploaded
once per database. To upload them again, write copies with new claim IDs:

```bash
elixir mock_data/generate.exs --tag 2 --out /tmp/samples2   # claim IDs end in -2
```

## Expected results

The business rules are the 17 active rules seeded by
`phoenix_web/priv/repo/seeds.exs`. "NPPES rejects" means the provider check
refuses the claim with a message containing the quoted text.

### clean

| File | What it shows | Expected |
|---|---|---|
| `office_visit.json` | Established-patient office visit | no rule |
| `preventive_care.json` | Annual preventive exam | no rule |
| `outpatient_lab.json` | Three lab tests from a pathology group | no rule |
| `specialist_consultation.json` | Orthopedic consultation with an X-ray | no rule |
| `inpatient_weekend_stay.json` | 837I inpatient stay dated on a Saturday | no rule (WeekendOfficeVisit skips claims with a facility type) |

### single_rule

Each file is named after the rule it targets. Where another rule must also
match, it's listed: any claim over $750,000 is also over $50,000.

| File | What it shows | Expected |
|---|---|---|
| `ExcessiveTotalCharges.json` | Total charges over $750,000 (below $1M) | ExcessiveTotalCharges, HighValueClaim |
| `ExtremeAmounts.json` | Total charges over $1,000,000 | ExcessiveTotalCharges, ExtremeAmounts, HighValueClaim |
| `FutureServiceDate.json` | Second service line dated 2099 | FutureServiceDate |
| `HighComplexityERVisit.json` | 99285 on the second line, claim over $10,000 | HighComplexityERVisit |
| `HighValueClaim.json` | Claim over $50,000 with authorization | HighValueClaim |
| `ImpossibleDates.json` | Second service line dated 1899 | ImpossibleDates; NPPES rejects ("was not issued until") |
| `InvalidNPIFormat.json` | Seven-digit billing NPI | InvalidNPIFormat, InvalidProviderNPI; NPPES rejects ("not found in NPPES") |
| `InvalidProviderNPI.json` | Real NPI with the last digit mistyped | InvalidProviderNPI; NPPES rejects ("not found in NPPES") |
| `MissingDiagnosisCodes.json` | Urgent care claim with no diagnosis codes | MissingDiagnosisCodes |
| `MissingProviderTaxonomy.json` | No taxonomy, claim over $1,000 | MissingProviderTaxonomy |
| `MissingRequiredFields.json` | Patient date of birth missing | MissingRequiredFields |
| `NewProviderLargeSubmission.json` | Provider credentialed 45 days ago, claim over $10,000 | NewProviderLargeSubmission |
| `PatientAgeOutOfRange.json` | Date of birth in 1890 | PatientAgeOutOfRange |
| `SuspiciouslyLowCharge.json` | Claim total of $2.00 | SuspiciouslyLowCharge |
| `TaxonomyMismatchNewProvider.json` | New provider, no taxonomy, claim over $5,000 | MissingProviderTaxonomy, TaxonomyMismatchNewProvider |
| `UnauthorizedProcedure.json` | Claim over $5,000 with no authorization | UnauthorizedProcedure |
| `WeekendOfficeVisit.json` | Saturday office visit over $500 | WeekendOfficeVisit |

### multi_rule

| File | What it shows | Expected |
|---|---|---|
| `new_provider_no_auth.json` | New dental provider, no taxonomy, no authorization, $35,000 | MissingProviderTaxonomy, NewProviderLargeSubmission, TaxonomyMismatchNewProvider, UnauthorizedProcedure |
| `er_visit_no_auth.json` | 99285 over $10,000 with no authorization | HighComplexityERVisit, UnauthorizedProcedure |
| `extreme_new_provider.json` | Over $1M, new provider, no authorization | ExcessiveTotalCharges, ExtremeAmounts, HighValueClaim, NewProviderLargeSubmission, UnauthorizedProcedure |
| `weekend_no_taxonomy.json` | Saturday office visit sent without a taxonomy | MissingProviderTaxonomy, WeekendOfficeVisit |

### nppes

| File | What it shows | Expected |
|---|---|---|
| `deactivated_provider.json` | NPI deactivated 2024-12-12, service in 2026 | NPPES rejects ("was deactivated") |
| `before_enumeration.json` | Service dated before the NPI was issued | NPPES rejects ("was not issued until") |
| `reactivation_gap.json` | Service while the NPI was deactivated, before its reactivation | NPPES rejects ("was deactivated") |
| `reactivated_provider.json` | Same reactivated NPI, service in 2026 | accepted |
| `dropped_provider.json` | NPI missing from the latest full NPPES file | NPPES rejects ("has not been in the NPPES file since") |
| `unissued_npi.json` | NPI with a valid check digit that was never issued | NPPES rejects ("not found in NPPES") |

`dropped_provider.json` relies on the registry having been imported from the
October 2026 full file, which marked `1093462368` as dropped on 2026-10-18.

### redundancy

Upload these after pasting `rules/redundancy_levels.dsl` into the Rules page
in place of the business rules. Or just read them alongside the rules: each
shows which overlapping rules fire together. The rules are in groups A–I;
the group G OR rules share the amount field, so they fire on every claim
over $50,000.

| File | What it shows | Expected |
|---|---|---|
| `exact_duplicate.json` | A, Level 1: two identical > $50,000 rules both fire | high_amount_50k, high_amount_50k_dup, high_amount_only, high_or_er, high_or_er_dup, moderate_amount_flag |
| `subsumption_extreme_amount.json` | A, Levels 2–3: > $100,000 inside > $50,000; the > $75,000 REJECT | extreme_amount_100k, high_amount_50k, high_amount_50k_dup, high_amount_only, high_amount_reject, high_or_er, high_or_er_dup, inpatient_high_amount, moderate_amount_flag |
| `overlap_mid_range.json` | A, Level 4: $55,000 is in both > $50,000 and $40,000–$60,000 | high_amount_50k, high_amount_50k_dup, high_amount_only, high_or_er, high_or_er_dup, mid_range_review, moderate_amount_flag |
| `new_provider_subsumption.json` | B, Levels 2–4: tenure 20 days | new_provider_90, new_provider_reject, provider_probation, very_new_provider_30 |
| `shadowed_er_visit.json` | C, Levels 1 and 3: ER place of service | er_visit_flag, er_visit_flag_copy, er_visit_reject, high_or_er, high_or_er_dup |
| `compound_all_levels.json` | A–D together: $80,000 ER claim, 45-day provider | er_visit_flag, er_visit_flag_copy, er_visit_reject, high_amount_50k, high_amount_50k_dup, high_amount_new_provider, high_amount_only, high_amount_reject, high_or_er, high_or_er_dup, moderate_amount_flag, moderate_amount_newer_provider, new_provider_90, new_provider_reject, provider_probation |
| `control_no_triggers.json` | Negative control | no rule |
| `string_diagnosis_dup.json` | E, Levels 1 and 3: principal diagnosis E11.9 | diabetes_flag, diabetes_flag_dup, diabetes_reject |
| `between_overlap.json` | F, Levels 1 and 4: 12 room-and-board days | stay_10_21, stay_7_14, stay_7_14_dup |
| `between_disjoint.json` | F control: 3 room-and-board days | stay_1_5 |
| `or_condition.json` | G: the amount arm of the OR | high_amount_50k, high_amount_50k_dup, high_amount_only, high_or_er, high_or_er_dup, moderate_amount_flag |
| `or_er_arm.json` | G: the ER arm of the OR | er_visit_flag, er_visit_flag_copy, er_visit_reject, high_or_er, high_or_er_dup |
| `negation.json` | H, Levels 1 and 3: a replacement claim (frequency 7) | not_original_flag, not_original_flag_dup, not_original_reject |
| `negation_control.json` | H control: an original claim | no rule |
| `multi_field_partial.json` | I: cardiology, inpatient hospital, $70,000 | cardio_high_amount, cardio_moderate, high_amount_50k, high_amount_50k_dup, high_amount_only, high_or_er, high_or_er_dup, inpatient_high_amount, moderate_amount_flag |
| `multi_field_no_overlap.json` | I control: same amount and POS, orthopedic taxonomy | high_amount_50k, high_amount_50k_dup, high_amount_only, high_or_er, high_or_er_dup, inpatient_high_amount, moderate_amount_flag |
| `cardiology_moderate.json` | I: cardiology at $30,000 | cardio_moderate |

Some rules come back **not checked** rather than not matched where a claim
lacks the field they test. The group F stay rules need a revenue code, which
professional claims don't have. The ER rules need a claim-level place of
service, which institutional claims don't have.

### batches

| File | What it shows | Expected |
|---|---|---|
| `mixed_batch.json` | Six claims: two clean, four matching different rules | 001, 002: no rule; 003: WeekendOfficeVisit; 004: UnauthorizedProcedure; 005: HighComplexityERVisit; 006: MissingDiagnosisCodes |
| `clean_batch.json` | Four clean claims from four providers | no rule on any |

## Rule files

- **`rules/redundancy_levels.dsl`** is 32 rules that overlap on purpose.
  Added to the Rules page one at a time in file order, the redundancy check
  reports exact duplicates, shadowed rules and condition overlaps. The
  comments mark which level each rule was written to show.
- **`rules/examples.dsl`** is 10 rules showing DSL features the business
  rules don't use: nested `EXISTS`, `NOT EXISTS`, `NOT FORALL`, `COUNT`,
  `in_list`, `starts_with`, `MATCHES`, `has_procedure`, `is_age_valid`,
  indexed paths and multiple actions. Each one parses, passes the Rules page
  schema check, and was checked to fire on a claim built for it.

## Checking the samples

With the engine running and the dev database seeded (active rules and the
NPPES registry):

```bash
cd phoenix_web
mix run --no-start test/scripts/verify_x12_suite.exs --suite ../mock_data
```

Each file goes through the same parsing as an upload, then the NPPES check
and the rules: the active business rules, or the rules file a manifest entry
names. The outcome is compared with `manifest.json`. After changing a
sample, edit `generate.exs` (not the JSON) and run
`elixir mock_data/generate.exs`.

`phoenix_web/test/medicaid_claims_checker/claims/json_claim_test.exs` also
checks that every file under `claims/` is accepted as an upload.
