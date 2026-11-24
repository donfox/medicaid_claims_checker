# Mock data

All the test data for the Medicaid Claims Checker: claim files to upload on
the home page (`http://localhost:4000/`), rule files to paste on the Rules
page (`/rules`), and the expected result of each one. The same files are used
for manual testing and by the automated tests and scripts.

## How it is organised

Files are grouped by the **use case** they test. Each use case has an ID from
the Frontend Use Cases list ([docs/FRONTEND_USE_CASES.md](../docs/FRONTEND_USE_CASES.md)).
The IDs are not in the folder or file names; [Every use case](#every-use-case)
lists them.

```
mock_data/
  <group>/                   one folder per kind of test
    <use case>/              a folder holding a use case's files
      <variant>.<ext>        the test files; the name says what the file does
    <use case>.<ext>         a use case with one or two files sits directly
                             in its group
```

For example, `claim_rule_checks/exact_thresholds/exactly_50000.x12` is a
claim of exactly $50,000.00 for use case R5. HighValueClaim needs more than
$50,000, so it must not match.

| Group folder | Use cases | What they test |
|---|---|---|
| `json_files/` | J1–J8 | Uploading `.json` files: one claim, a wrapped list, entries that aren't claims, engine requests |
| `x12_files/` | X1–X7 | Uploading `.x12` files: 837P/I/D, several claims or transaction sets, line endings, broken files |
| `x12_files/edi_extension/` | E1–E3 | Uploading `.edi` files: alternate delimiters, a file that isn't X12 |
| `zip_files/` | Z1–Z7 | Uploading `.zip` files: mixed contents, path traversal, the 15,000-claim limit |
| `claim_rule_checks/` | R1–R11 | What the 20 business rules match |
| `nppes_provider_checks/` | N1–N11 | The NPPES provider check: malformed, unissued, deactivated, reactivated, dropped NPIs |
| `rules_page/` | P1–P4 | Rule files for the Rules page |
| `converter_output/` | none | Inputs for one internal processing step (see below); never uploaded |

Every use case has test data. U1–U8 (upload behaviour), N1 (active provider)
and R8 (new-provider rules) have no file of their own and use files from other
folders.

**One home per file.** Some files test more than one use case. Every R2 X12
file is also an 837P file (X1), for instance. Each file lives in the folder of
the use case it was written for.

**JSON and X12 side by side.** Where a case exists in both formats, both
files are in the same folder: `each_rule_alone/HighValueClaim.json` and
`HighValueClaim.x12`. They are separate claims and can expect slightly
different results; `manifest.json` has each one's.

### Every use case

| ID | Folder or file | Contents |
|---|---|---|
| J1 | `json_files/routine_office_visit.json` | One claim in a `.json` file |
| J2 | `json_files/two_claims.json` | A plain list `[...]` of claims, no wrapper |
| J3 | `json_files/claims_wrapper/` | Claims wrapped as `{"claims": [...]}`: `mixed_batch`, `clean_batch`, `mixed_risk` |
| J4 | `json_files/list_with_bad_entries.json` | A list holding claims and entries that aren't claims |
| J5 | `json_files/patient_record.json` | Valid JSON that isn't a claim: refused |
| J6 | `json_files/rules_text_and_claims.json` | An engine request (`rulesText` + claims), which must be refused as an upload |
| J7 | `json_files/invalid_json.json` | A claim file cut off part-way: not valid JSON, refused |
| J8 | `json_files/dental_837d.json`, `institutional_837i.json` | JSON claims in the 837D (dental) and 837I (institutional) layouts |
| X1 | `x12_files/837p_professional/` | Clean 837P claims, incl. a line dated as a range, a dependant patient and procedure modifiers |
| X2 | `x12_files/837i_institutional/` | 837I claims: dated on the line or on the claim only, and condition codes with no diagnosis |
| X3 | `x12_files/dental.x12` | An 837D claim |
| X4 | `x12_files/three_claims.x12`, `two_claims_same_subscriber.x12` | Three claims in one transaction set; two claims for one subscriber |
| X5 | `x12_files/two_transaction_sets.x12` | Two transaction sets in one file |
| X6 | `x12_files/no_newlines.x12`, `crlf_line_endings.x12` | No newlines; CRLF line endings |
| X7 | `x12_files/broken_envelope_or_file/` | Truncated, wrong segment count, mismatched control numbers, too short, no claims |
| E1 | `x12_files/edi_extension/clean_claim.edi` | An ordinary clean 837P claim named `.edi` |
| E2 | `x12_files/edi_extension/alternate_delimiters.edi` | `\|` and `>` as separators |
| E3 | `x12_files/edi_extension/not_x12.edi` | Plain text named `.edi` |
| Z1 | `zip_files/mixed_file_types.zip` | A zip with `.x12`, `.edi`, `.json` and an ignored `.txt` |
| Z2 | `zip_files/two_json_claims.zip` | A zip holding only `.json` claims |
| Z3 | `zip_files/path_traversal.zip` | A zip entry named `../escape.x12` |
| Z4 | `zip_files/empty.zip`, `text_files_only.zip` | An empty zip; a zip of `.txt`/`.csv` only: nothing to evaluate |
| Z5 | `zip_files/zip_inside_zip.zip` | A zip holding an `.x12` and another zip, which is ignored |
| Z6 | `zip_files/corrupt.zip` | A zip cut off part-way, which can't be opened |
| Z7 | `zip_files/over_15000_claims/` | Not committed: made by `generate.exs --large N` (the use-case test builds its own) |
| R1 | `claim_rule_checks/clean_claim/` | Claims no rule should match |
| R2 | `claim_rule_checks/each_rule_alone/` | One file per rule, named after it |
| R3 | `claim_rule_checks/several_rules/` | Claims that match several rules |
| R4 | `claim_rule_checks/problem_on_second_line/` | The problem is on service line 2, not line 1 |
| R5 | `claim_rule_checks/exact_thresholds/` | Amounts exactly at a "greater than" limit, which must not match |
| R6 | `claim_rule_checks/weekend_office_variants/` | Saturday, Sunday, weekday and home-visit variants of WeekendOfficeVisit |
| R7 | `claim_rule_checks/inpatient_weekend.x12`, `inpatient_weekend_stay.json` | Weekend inpatient stays, which WeekendOfficeVisit must skip |
| R9 | `claim_rule_checks/missing_taxonomy_new_provider.x12` | A rule reported "not checked" because the claim lacks its field |
| R10 | `claim_rule_checks/age_out_of_range_or_missing_dob/` | Born 1880, born 2099, no date of birth |
| R11 | `claim_rule_checks/replacement_or_void_claim/` | Frequency codes 7 and 8: the rules apply as to an original |
| N2 | `nppes_provider_checks/bad_checksum.x12`, `nine_digit_npi.x12` | Wrong length; failed check digit |
| N3 | `nppes_provider_checks/unissued_npi.json`, `unissued_npi.x12` | Valid check digit, never issued |
| N4 | `nppes_provider_checks/deactivated_provider.json`, `deactivated_provider.x12` | Deactivated 2024-12-12, service in 2026 |
| N5 | `nppes_provider_checks/service_before_deactivation.x12` | Same provider, service before the deactivation: accepted |
| N6 | `nppes_provider_checks/deactivated_mid_claim.x12` | One line before and one after the deactivation |
| N7 | `nppes_provider_checks/reactivated_provider/` | Service after reactivation (accepted) and in the gap (rejected) |
| N8 | `nppes_provider_checks/before_enumeration.json` | Service dated before the NPI existed |
| N9 | `nppes_provider_checks/dropped_provider.json` | NPI dropped from the NPPES file (needs the October 2026 import) |
| N10 | `nppes_provider_checks/missing_billing_npi.x12` | No billing NPI |
| N11 | `nppes_provider_checks/rendering_npi_deactivated.x12` | Valid billing NPI, deactivated rendering provider |
| P1 | `rules_page/feature_examples.dsl` | DSL features the business rules don't use |
| P2 | `rules_page/redundancy_levels/` | `redundancy_levels.dsl` and the claims written for it (`claims/`) |
| P3 | `rules_page/missing_then.dsl` | A rule with a syntax error: shown as an issue, not saved |
| P4 | `rules_page/old_field_name.dsl` | A rule using an old field name: saved as an inactive draft, with the current name suggested |

## Generated and hand-written files

Most files are **generated**: written by `generate.exs` from the case
definitions in `test_case_generators/`, together with `manifest.json`, the expected
result of each generated file. To change one, edit the generator and run it
again; an edit to the file itself is lost on the next run.

```bash
elixir mock_data/generate.exs              # rewrite every generated file
elixir mock_data/generate.exs --large 15001 # also write a Z7 large-batch zip (not committed)
```

| Generator | Writes |
|---|---|
| `test_case_generators/x12_files.exs` | every `.x12`, `.edi` and `.zip` file |
| `test_case_generators/json_claims.exs` | the JSON claims in R, N and P2, and the files for J2, J3 (`clean_batch`, `mixed_batch`), J5, J7 and J8 |

The generator deletes the files the previous `manifest.json` lists before
writing, so renaming or removing a case leaves nothing behind. It never
touches the **hand-written** files, which are not in the manifest:

- `json_files/routine_office_visit.json`
- `json_files/claims_wrapper/mixed_risk.json`
- `json_files/list_with_bad_entries.json`
- `json_files/rules_text_and_claims.json`
- the `.dsl` files in `rules_page/`
- `converter_output/`

### `converter_output/`

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
  MissingTaxonomyNewProvider) can only be exercised with JSON claims.

## Expected results

`manifest.json` holds the expected result of every generated file:

- `matched` is exactly the set of rules that should match: the 20 active
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
mix run --no-start ../mock_data/verify.exs --large ../mock_data/zip_files/over_15000_claims/large_batch_15001.zip
```

`--only` takes a use case ID or a group letter. X includes the E cases, which
sit under `x12_files/`. J1, J4, J6, N1, P1, P3, P4, R8, U1–U8 and Z7 have no
manifest case of their own, so check them with `scripts/test.sh`, for example
`scripts/test.sh J1 Z7`.

Each file goes through the same steps as an upload, then the NPPES check and
the rules, and the outcome is compared with `manifest.json`. Hand-written
files aren't in the manifest; the Phoenix tests (`mix test`) check those.

`scripts/test.sh` at the repo root checks the same files through the app itself:
each is uploaded on the home page (or entered on the Rules page) and
evaluated by an engine the script starts. It also covers the hand-written
files and the use cases with no file of their own (U1–U8, N1, R8). The tests
are in `phoenix_web/test/use_cases/`; see [docs/TEST_PROCEDURE.md](../docs/TEST_PROCEDURE.md).

### `nppes_extract.json`

The NPPES registry rows for every NPI in the mock data, copied from the dev
database, which `scripts/test.sh` loads into the empty test database. Rewrite it
after an NPPES re-import or after adding a provider to the mock data:

```bash
cd phoenix_web && mix run --no-start ../mock_data/export_nppes_extract.exs
```

## Uploading a file more than once

Phoenix refuses a file or claim it has already received. The development-only
re-submit checkbox on the upload page lets the same files through; see
[Uploading the same files again](../docs/FRONTEND_USE_CASES.md#uploading-the-same-files-again).
To make copies whose claim IDs end in `-N` instead, using a new N each round:

```bash
elixir mock_data/retag.exs --tag 3 --out ~/upload_round3 mock_data
```

The copy keeps the expected results (`manifest.json` is retagged too), so
`verify.exs --suite ~/upload_round3/mock_data` checks it.

## The rule files

- **`redundancy_levels/redundancy_levels.dsl`** is 32 rules that overlap
  on purpose. Added to the Rules page one at a time in file order, the
  redundancy check reports all four levels: exact duplicates, subsumed rules,
  shadowed rules and condition overlaps. Comments mark which level each rule
  was written to show. The claims in `redundancy_levels/claims/` show
  which overlapping rules fire together. The rules are in groups A–I; the
  group G OR rules share the amount field, so they fire on every claim over
  $50,000. Some rules come back "not checked" where a claim lacks the field:
  the group F stay rules need a revenue code, which professional claims don't
  have, and the ER rules need a claim-level place of service, which
  institutional claims don't have.
- **`feature_examples.dsl`** is 10 rules showing DSL features the
  business rules don't use: nested `EXISTS`, `NOT EXISTS`, `NOT FORALL`,
  `COUNT`, `in_list`, `starts_with`, `MATCHES`, `has_procedure`,
  `is_age_valid`, indexed paths and multiple actions. Each one parses, passes
  the Rules page schema check, and was checked to fire on a claim built for
  it.
