# Mock data

All the test data for the Medicaid Claims Checker: claim files to upload on
the home page (`http://localhost:4000/`), rule files to paste on the Rules
page (`/rules`), and the expected result of each one. The same files are used
for manual testing and by the automated tests and scripts.

## How it is organised

Files are grouped by the **use case** they test, using the IDs from the
Frontend Use Cases list (`docs/testing/Frontend_Use_Cases.pdf`):

```
mock_data/
  <group>/                   one folder per kind of test, named <letter>_<what it covers>
    <ID>_<use case>/         one folder per use case, named <ID>_<what it tests>
      <variant>.<ext>        the test files; the name says what the file does
```

For example, `R_business_rules/R5_exact_thresholds/exactly_50000.x12` is a
claim of exactly $50,000.00 for use case R5 (rules must not match at exactly
the limit).

| Group folder | Use cases | What they test |
|---|---|---|
| `J_json_files/` | J1–J8 | Uploading `.json` files: one claim, a wrapped list, entries that aren't claims, engine requests |
| `X_x12_files/` | X1–X7 | Uploading `.x12` files: 837P/I/D, several claims or transaction sets, line endings, broken files |
| `E_edi_files/` | E1–E3 | Uploading `.edi` files: alternate delimiters, a file that isn't X12 |
| `Z_zip_files/` | Z1–Z7 | Uploading `.zip` files: mixed contents, path traversal, the 15,000-claim limit |
| `R_business_rules/` | R1–R11 | What the 17 business rules match |
| `N_nppes_provider_checks/` | N1–N11 | The NPPES provider check: malformed, unissued, deactivated, reactivated, dropped NPIs |
| `P_rules_page/` | P1–P4 | Rule files for the Rules page |
| `pipeline/` | none | Inputs for one internal processing step (see below); never uploaded |

A use case with no folder has no test file yet. The use-case list says which
those are; U1–U8 (upload behaviour) and N1 (active provider) use files from
other folders.

**One home per file.** Some files test more than one use case. Every R2 X12
file is also an 837P file (X1), for instance. Each file lives in the folder of
the use case it was written for.

**JSON and X12 side by side.** Where a case exists in both formats, both
files are in the same folder: `R2_each_rule_alone/HighValueClaim.json` and
`HighValueClaim.x12`. They are separate claims and can expect slightly
different results; `manifest.json` has each one's.

### Every use-case folder

| Folder | Contents |
|---|---|
| `J_json_files/J1_one_claim/` | One claim in a `.json` file |
| `J_json_files/J3_claims_wrapper/` | Claims wrapped as `{"claims": [...]}`: `mixed_batch`, `clean_batch`, `mixed_risk` |
| `J_json_files/J4_claims_mixed_with_non_claims/` | A list holding claims and entries that aren't claims |
| `J_json_files/J6_engine_request/` | An engine request (`rulesText` + claims), which must be refused as an upload |
| `X_x12_files/X1_837p_professional/` | Clean 837P claims |
| `X_x12_files/X2_837i_institutional/` | An 837I claim |
| `X_x12_files/X3_837d_dental/` | An 837D claim |
| `X_x12_files/X4_several_claims_one_transaction_set/` | Three claims in one transaction set; two claims for one subscriber |
| `X_x12_files/X5_several_transaction_sets/` | Two transaction sets in one file |
| `X_x12_files/X6_one_line_or_windows_line_endings/` | No newlines; CRLF line endings |
| `X_x12_files/X7_broken_envelope_or_file/` | Truncated, wrong segment count, mismatched control numbers, too short, no claims |
| `E_edi_files/E2_alternate_delimiters/` | `\|` and `>` as separators |
| `E_edi_files/E3_not_x12/` | Plain text named `.edi` |
| `Z_zip_files/Z1_mixed_file_types/` | A zip with `.x12`, `.edi`, `.json` and an ignored `.txt` |
| `Z_zip_files/Z3_path_traversal/` | A zip entry named `../escape.x12` |
| `Z_zip_files/Z7_over_15000_claims/` | Not committed: made by `generate.exs --large N` |
| `R_business_rules/R1_clean_claim/` | Claims no rule should match |
| `R_business_rules/R2_each_rule_alone/` | One file per rule, named after it |
| `R_business_rules/R3_several_rules/` | Claims that match several rules |
| `R_business_rules/R4_problem_on_second_line/` | The problem is on service line 2, not line 1 |
| `R_business_rules/R5_exact_thresholds/` | Amounts exactly at a "greater than" limit, which must not match |
| `R_business_rules/R6_weekend_office_variants/` | Saturday, Sunday, weekday and home-visit variants of WeekendOfficeVisit |
| `R_business_rules/R7_weekend_inpatient_stay/` | Weekend inpatient stays, which WeekendOfficeVisit must skip |
| `R_business_rules/R9_rule_not_decidable/` | A rule reported "not checked" because the claim lacks its field |
| `R_business_rules/R10_age_out_of_range_or_missing_dob/` | Born 1880, born 2099, no date of birth |
| `N_nppes_provider_checks/N2_malformed_npi/` | Wrong length; failed check digit |
| `N_nppes_provider_checks/N3_npi_never_issued/` | Valid check digit, never issued |
| `N_nppes_provider_checks/N4_deactivated_provider/` | Deactivated 2024-12-12, service in 2026 |
| `N_nppes_provider_checks/N5_service_before_deactivation/` | Same provider, service before the deactivation: accepted |
| `N_nppes_provider_checks/N6_deactivated_mid_claim/` | One line before and one after the deactivation |
| `N_nppes_provider_checks/N7_reactivated_provider/` | Service after reactivation (accepted) and in the gap (rejected) |
| `N_nppes_provider_checks/N8_service_before_npi_issued/` | Service dated before the NPI existed |
| `N_nppes_provider_checks/N9_dropped_from_nppes/` | NPI dropped from the NPPES file (needs the October 2026 import) |
| `N_nppes_provider_checks/N10_no_billing_npi/` | No billing NPI |
| `N_nppes_provider_checks/N11_deactivated_rendering_provider/` | Valid billing NPI, deactivated rendering provider |
| `P_rules_page/P1_feature_examples/` | `examples.dsl`: DSL features the business rules don't use |
| `P_rules_page/P2_redundancy_levels/` | `redundancy_levels.dsl` and the claims written for it (`claims/`) |

## Generated and hand-written files

Most files are **generated**: written by `generate.exs` from the case
definitions in `generators/`, together with `manifest.json`, the expected
result of each generated file. To change one, edit the generator and run it
again; an edit to the file itself is lost on the next run.

```bash
elixir mock_data/generate.exs              # rewrite every generated file
elixir mock_data/generate.exs --large 15000 # also write a Z7 large-batch zip (not committed)
```

| Generator | Writes |
|---|---|
| `generators/x12_files.exs` | every `.x12`, `.edi` and `.zip` file |
| `generators/json_claims.exs` | the JSON claims in R, N and P2, and the J3 batches |

The generator deletes the files the previous `manifest.json` lists before
writing, so renaming or removing a case leaves nothing behind. It never
touches the **hand-written** files, which are not in the manifest:

- `J_json_files/J1_one_claim/routine_office_visit.json`
- `J_json_files/J3_claims_wrapper/mixed_risk.json`
- `J_json_files/J4_claims_mixed_with_non_claims/list_with_bad_entries.json`
- `J_json_files/J6_engine_request/rules_text_and_claims.json`
- the two `.dsl` files in `P_rules_page/`
- `pipeline/converter_output/`

### `pipeline/converter_output/`

Two 837P claims as the X12 converter outputs them, before
`X12.SegmentMapper.normalize` turns them into the layout the rules see. The
segment mapper and evaluator tests start from these. They aren't uploads, so
they belong to no use case.

## What the claims contain

- **Layout.** JSON claims use the field layout the rules see, the output of
  `X12.SegmentMapper.normalize`, so a rule that works on a JSON claim works
  on a converted 837. Diagnosis codes are written as an 837 carries them,
  without the dot (`E119`, not `E11.9`).
- **Providers are real.** Names, NPIs, primary taxonomies and practice
  addresses come from the NPI Registry (checked 2026-10-19). Service dates
  are in 2026, when these providers were active. The exceptions are
  deliberate: invalid NPIs (`1234567`, `1234567890`, `1003001578`,
  `1999999992`, and the malformed ones in N2), and the deactivated
  (`1003002304`) and dropped (`1093462368`) NPIs, which have no public name
  or address. Each JSON claim's `sample_notes` says which it uses; rules
  ignore that field.
- **Patients are synthetic**, as are member IDs, tax IDs and authorization
  numbers.
- **Fields only JSON can carry.** `provider.tenure_days` is never filled by
  X12 conversion, so the two new-provider rules (NewProviderLargeSubmission,
  TaxonomyMismatchNewProvider) can only be exercised with JSON claims.

## Expected results

`manifest.json` holds the expected result of every generated file:

- `matched` is exactly the set of rules that should match: the 17 active
  rules seeded by `phoenix_web/priv/repo/seeds.exs`, or the rules file named
  in `rules` (the P2 claims use `redundancy_levels.dsl`).
- `not_checked` is exactly the set of rules that must come back "not
  checked". Any other rule left not checked fails the case.
- `nppes` is `ok`, or text the NPPES rejection must contain.
- `known_issue` marks a case the current code gets wrong. It reports XFAIL
  while the bug remains and XPASS once it is fixed; then delete the
  `known_issue` in the generator.

Rules that aren't active in the database are left out of the comparison. A
new or changed business rule can change the expected results.

## Checking the files

With the engine running and the dev database seeded (active rules and the
NPPES registry):

```bash
cd phoenix_web
mix run --no-start ../mock_data/verify.exs             # every generated file
mix run --no-start ../mock_data/verify.exs --only R5   # one use case
mix run --no-start ../mock_data/verify.exs --only N    # one group
mix run --no-start ../mock_data/verify.exs --large ../mock_data/Z_zip_files/Z7_over_15000_claims/large_batch_15000.zip
```

Each file goes through the same steps as an upload, then the NPPES check and
the rules, and the outcome is compared with `manifest.json`. Hand-written
files aren't in the manifest; the Phoenix tests (`mix test`) check those.

## Uploading a file more than once

Phoenix refuses a file it has already received and a claim it has already
evaluated. To upload the same data again, either tick the development-only
re-submit checkbox on the upload page, or make copies whose claim IDs end in
`-N`, using a new N each round:

```bash
elixir mock_data/retag.exs --tag 3 --out ~/upload_round3 mock_data
```

The copy keeps the expected results (`manifest.json` is retagged too), so
`verify.exs --suite ~/upload_round3/mock_data` checks it.

## The rule files

- **`P2_redundancy_levels/redundancy_levels.dsl`** is 32 rules that overlap
  on purpose. Added to the Rules page one at a time in file order, the
  redundancy check reports all four levels: exact duplicates, subsumed rules,
  shadowed rules and condition overlaps. Comments mark which level each rule
  was written to show. The claims in `P2_redundancy_levels/claims/` show
  which overlapping rules fire together. The rules are in groups A–I; the
  group G OR rules share the amount field, so they fire on every claim over
  $50,000. Some rules come back "not checked" where a claim lacks the field:
  the group F stay rules need a revenue code, which professional claims don't
  have, and the ER rules need a claim-level place of service, which
  institutional claims don't have.
- **`P1_feature_examples/examples.dsl`** is 10 rules showing DSL features the
  business rules don't use: nested `EXISTS`, `NOT EXISTS`, `NOT FORALL`,
  `COUNT`, `in_list`, `starts_with`, `MATCHES`, `has_procedure`,
  `is_age_valid`, indexed paths and multiple actions. Each one parses, passes
  the Rules page schema check, and was checked to fire on a claim built for
  it.
