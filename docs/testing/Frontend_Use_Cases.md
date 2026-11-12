<!--
  Expected results come from mock_data/manifest.json and the use-case tests
  in phoenix_web/test/use_cases/; keep them in step.
-->

# Frontend Use Cases

*Medicaid Claims Checker · test plan for the running app · status as of October 21, 2026*

> **What this is.** The agreed list of things to test in the running Medicaid Claims Checker through its web pages: the
> Fetch Source page (`http://localhost:4000/`, Manual Upload and Batch History) and the Rules page (`/rules`). Each use
> case names its test files and what the app should show. Engine-only checks are out of scope.

**59** use cases · **59** with test data · **59** checked automatically by `./test.sh`

## Before you start

- The engine and Phoenix are running (`./start.sh`); the dev database has the 17 seeded active rules and the October 2026
  NPPES import.
- Leave **Test upload: allow re-submission** ticked on the upload page so files can be uploaded again (see the companion
  guide [Repeat Testing with Mock Data](Repeat_Testing_Guide.md)). Untick it only for U4–U6.
- Every path below is relative to `mock_data/`. Each use case has its own folder, `<group>/<ID>_<name>/`; the table names
  the folder and the files in it. The exact expected result of every generated file is in `mock_data/manifest.json`.
- Use cases with no folder of their own (N1, R8, U1–U8) use files from other folders.
- A claim “matches” a rule when the rule fires on it; “Clean” means no rule matches and the NPPES check passes.
- `./test.sh` runs all 59 through the real pages; `./test.sh R5 N7` runs only those.

## J — JSON uploads

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **J1** | One claim in a .json file | `J_json_files/J1_one_claim/` routine_office_visit.json | “1 JSON claim(s) submitted for evaluation”; the claim is evaluated. |
| **J2** | A list of claims `[ … ]` | `J_json_files/J2_list_of_claims/` two_claims.json | Both claims evaluated: MOCK-LIST-001 Clean; MOCK-LIST-002 matches MissingDiagnosisCodes. |
| **J3** | Claims wrapped as `{"claims": [ … ]}` | `J_json_files/J3_claims_wrapper/` mixed_batch.json, clean_batch.json, mixed_risk.json | Every claim evaluated. clean_batch: 4 Clean. mixed_batch: 2 Clean, then WeekendOfficeVisit, UnauthorizedProcedure, HighComplexityERVisit, MissingDiagnosisCodes. |
| **J4** | Claims mixed with non-claim entries | `J_json_files/J4_claims_mixed_with_non_claims/` list_with_bad_entries.json | The claims are evaluated; the final message still says “Not accepted: list_with_bad_entries.json (entry …)”, naming each refused entry. |
| **J5** | A JSON file that is not a claim | `J_json_files/J5_not_a_claim/` patient_record.json | Refused: “no claim found (expected a claim_id or claim field)”; nothing evaluated. |
| **J6** | An engine request (rulesText + claims) | `J_json_files/J6_engine_request/` rules_text_and_claims.json | Refused as “an engine test request (rules and a list of claims), not a claims file”; nothing evaluated. |
| **J7** | Invalid JSON | `J_json_files/J7_invalid_json/` cut_off.json | Refused: “not valid JSON”. |
| **J8** | Dental / institutional claim as JSON | `J_json_files/J8_837i_or_837d_style_json/` dental_837d.json, institutional_837i.json | Evaluated like a converted 837D / 837I; both Clean. |

## X — X12 (.x12) uploads

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **X1** | 837P professional claim | `X_x12_files/X1_837p_professional/` clean_office_visit.x12, clean_multi_line.x12 | “1 X12/EDI claim(s) translated”; Clean. |
| **X2** | 837I institutional claim | `X_x12_files/X2_837i_institutional/` institutional.x12 | Translated and evaluated; Clean. |
| **X3** | 837D dental claim | `X_x12_files/X3_837d_dental/` dental.x12 | Translated and evaluated; Clean. |
| **X4** | Several claims in one transaction set | `X_x12_files/X4_several_claims_one_transaction_set/` three_claims.x12, two_claims_same_subscriber.x12 | Each claim is its own result row. three_claims: MULTI01 Clean; MULTI02 HighValueClaim + HighComplexityERVisit + UnauthorizedProcedure; MULTI03 MissingDiagnosisCodes. Same subscriber: SAMESUB01 Clean, SAMESUB02 SuspiciouslyLowCharge. |
| **X5** | Several transaction sets in one file | `X_x12_files/X5_several_transaction_sets/` two_transaction_sets.x12 | All four claims from both sets are evaluated; TXA02 SuspiciouslyLowCharge, TXB02 PatientAgeOutOfRange. |
| **X6** | One-line file / Windows line endings | `X_x12_files/X6_one_line_or_windows_line_endings/` no_newlines.x12, crlf_line_endings.x12 | Read like a normal file; Clean. |
| **X7** | Broken envelope or file | `X_x12_files/X7_broken_envelope_or_file/` truncated, wrong_se_count, control_number_mismatch, too_short, envelope_no_claims (.x12) | Refused, naming the problem: “incomplete transmission”, “SE segment count”, “interchange control number mismatch”, “too short”, “no claims found”. No claims evaluated. |

## E — EDI (.edi) uploads

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **E1** | A plain, clean .edi file | `E_edi_files/E1_plain_edi/` clean_claim.edi | Treated exactly like .x12; Clean. |
| **E2** | Alternate delimiters (`\|` and `>`) | `E_edi_files/E2_alternate_delimiters/` alternate_delimiters.edi | Translated; HighComplexityERVisit + UnauthorizedProcedure. |
| **E3** | A file that is not X12 at all | `E_edi_files/E3_not_x12/` not_x12.edi | Refused as not X12 (“must start with ISA”). |

## Z — Zip uploads

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **Z1** | Zip with .x12, .edi, .json and other files | `Z_zip_files/Z1_mixed_file_types/` mixed_bundle.zip | The three claim files are evaluated (ZIPEDIB matches MissingDiagnosisCodes); README.txt is ignored. |
| **Z2** | Zip with JSON files only | `Z_zip_files/Z2_json_only_zip/` two_json_claims.zip | Both JSON claims evaluated; Clean. |
| **Z3** | Path-traversal entry (`../escape.x12`) | `Z_zip_files/Z3_path_traversal/` path_traversal.zip | Read as escape.x12 and evaluated (Clean); nothing is written to disk. |
| **Z4** | Zip with nothing usable / empty zip | `Z_zip_files/Z4_nothing_usable/` empty.zip, text_files_only.zip | “No processable claims found”. |
| **Z5** | Zip inside a zip | `Z_zip_files/Z5_zip_inside_zip/` nested.zip | The outer .x12 is evaluated (Clean); the inner zip is ignored. |
| **Z6** | Corrupt zip | `Z_zip_files/Z6_corrupt_zip/` cut_off.zip | “No processable claims found”. |
| **Z7** | More than 15,000 claims | `Z_zip_files/Z7_over_15000_claims/` — not in git; make it with `elixir mock_data/generate.exs --large 15001` | Nothing is evaluated. The message names the reason: “This batch has 15001 claims; the limit is 15000. Split the files into smaller batches and try again.” Up to 15,000 claims are evaluated normally. |

## U — Upload behaviour

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **U1** | Several files of mixed types at once | For example R2_each_rule_alone/HighValueClaim.json, X1…/clean_office_visit.x12, Z1…/mixed_bundle.zip | Every file’s claims are evaluated in one batch. |
| **U2** | Unsupported file type (.txt, .pdf) | Any non-claim file | “File type not accepted. Allowed: .json, .x12, .edi, .zip”, before upload. |
| **U3** | File over 10 MB | Any file over 10 MB (not kept in git) | “File is too large (max 10 MB).”, before upload. |
| **U4** | Same file uploaded twice | Any claim file, checkbox unticked | Second time: “Nothing was evaluated: every claim was already submitted…”, and a red notice in Batch History. |
| **U5** | Same claim in a different file | A copy of an uploaded file with one extra line at the end, checkbox unticked | The claim is refused as already submitted, naming the earlier batch; other claims are evaluated. |
| **U6** | Same claim twice in one file | A JSON list holding one claim twice, checkbox unticked | Only the first copy is evaluated; the second is refused (“appears twice in this submission”). |
| **U7** | Void / replacement (frequency 8 / 7) | `R_business_rules/R11_replacement_or_void_claim/` | Accepted: a void or replacement is not a duplicate of the original. |
| **U8** | Re-uploading test data | Any file, with **Test upload: allow re-submission** ticked | The same file is evaluated again; the batch name ends in “(test re-submission)”. |

## R — Business rules (17 active rules)

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **R1** | Clean claim | `R_business_rules/R1_clean_claim/` office_visit, outpatient_lab, preventive_care, specialist_consultation (.json) | No rule matches; Clean. |
| **R2** | Each rule on its own | `R_business_rules/R2_each_rule_alone/` &lt;RuleName&gt;.json and .x12, one per rule | The named rule matches. Rules that always go together match too (ExtremeAmounts brings ExcessiveTotalCharges and HighValueClaim); the X12 files also match UnauthorizedProcedure where the claim has no authorization. |
| **R3** | Several rules on one claim | `R_business_rules/R3_several_rules/` 4 JSON files, many_rules.x12 | Every expected rule matches (manifest.json lists them). |
| **R4** | Problem on the 2nd service line | `R_business_rules/R4_problem_on_second_line/` er_99285_line2, future_date_line2, pre1900_line2 (.x12) | HighComplexityERVisit, FutureServiceDate and ImpossibleDates match: rules check every line, not just the first. |
| **R5** | Exact thresholds | `R_business_rules/R5_exact_thresholds/` exactly_5, exactly_500_weekend_office, exactly_5000, exactly_50000 (.x12) | “Greater than” limits don’t match at exactly the limit (exactly_50000 matches only UnauthorizedProcedure). |
| **R6** | Weekend office visit variants | `R_business_rules/R6_weekend_office_variants/` saturday_office, sunday_office, weekday_office_no_match, saturday_home_visit_no_match (.x12) | Saturday and Sunday office visits match WeekendOfficeVisit; weekday and home visits don’t. |
| **R7** | Weekend inpatient stay | `R_business_rules/R7_weekend_inpatient_stay/` inpatient_weekend.x12, inpatient_weekend_stay.json | WeekendOfficeVisit doesn’t match; Clean. |
| **R8** | New-provider rules (tenure) | `R_business_rules/R2_each_rule_alone/` NewProviderLargeSubmission.json, TaxonomyMismatchNewProvider.json | Match on JSON claims (tenure comes only from JSON). |
| **R9** | Rule that cannot be decided | `R_business_rules/R9_rule_not_decidable/` missing_taxonomy_new_provider.x12 | TaxonomyMismatchNewProvider shown as “Not checked”, naming the missing field. |
| **R10** | Patient age out of range / missing DOB | `R_business_rules/R10_age_out_of_range_or_missing_dob/` born_1880, born_2099, missing_dob (.x12) | PatientAgeOutOfRange for 1880 and 2099; MissingRequiredFields for no date of birth. |
| **R11** | Void / replacement against business rules | `R_business_rules/R11_replacement_or_void_claim/` replacement_frequency_7, void_frequency_8 (.json and .x12) | The rules apply as to an original claim: HighValueClaim matches (the X12 files also match UnauthorizedProcedure). |

## N — NPPES provider checks

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **N1** | Active provider | Any clean claim, e.g. R1_clean_claim/ | NPPES check passes. |
| **N2** | Malformed NPI (length / check digit) | `N_nppes_provider_checks/N2_malformed_npi/` nine_digit_npi.x12, bad_checksum.x12 | InvalidProviderNPI (and InvalidNPIFormat for 9 digits); NPPES: “not found in NPPES”. |
| **N3** | NPI never issued | `N_nppes_provider_checks/N3_npi_never_issued/` unissued_npi (.json and .x12) | “not found in NPPES”. |
| **N4** | Deactivated provider | `N_nppes_provider_checks/N4_deactivated_provider/` deactivated_provider (.json and .x12) | “was deactivated”. |
| **N5** | Service before the deactivation | `N_nppes_provider_checks/N5_service_before_deactivation/` service_before_deactivation.x12 | Accepted; Clean. |
| **N6** | Deactivated part-way through a claim | `N_nppes_provider_checks/N6_deactivated_mid_claim/` deactivated_mid_claim.x12 | Rejected for the later line: “service rendered on 2024-12-20 …”. |
| **N7** | Reactivated provider / service in the gap | `N_nppes_provider_checks/N7_reactivated_provider/` reactivated_provider, reactivation_gap (.json and .x12) | Accepted after reactivation; “was deactivated” for service inside the gap. |
| **N8** | Service before the NPI was issued | `N_nppes_provider_checks/N8_service_before_npi_issued/` before_enumeration.json | “was not issued until …”. |
| **N9** | Provider dropped from the NPPES file | `N_nppes_provider_checks/N9_dropped_from_nppes/` dropped_provider.json | “has not been in the NPPES file since …” (needs the October 2026 import). |
| **N10** | No billing NPI | `N_nppes_provider_checks/N10_no_billing_npi/` missing_billing_npi.x12 | MissingRequiredFields. |
| **N11** | Deactivated rendering provider | `N_nppes_provider_checks/N11_deactivated_rendering_provider/` rendering_npi_deactivated.x12 | NPPES rejects the rendering provider: “was deactivated”. |

## P — Rules page

| ID | Use case | Test files | What the app should show |
|---|---|---|---|
| **P1** | Feature examples | `P_rules_page/P1_feature_examples/` examples.dsl | Each of the 10 rules parses, passes the schema check and saves as an active rule. |
| **P2** | Redundancy levels | `P_rules_page/P2_redundancy_levels/` redundancy_levels.dsl (add in file order) | Exact duplicate, subsumption, shadowed and overlap warnings each appear where the file’s comments say. |
| **P3** | Rule with a syntax error | `P_rules_page/P3_syntax_error/` missing_then.dsl | “Rule syntax issue” shown while typing; saving gives “Could not save rule”; nothing saved. |
| **P4** | Rule naming an unknown field | `P_rules_page/P4_unknown_field/` old_field_name.dsl | Saved as an inactive draft, with the current name suggested (“subscriber.subscriber_id -> subscriber.member_id”). |
