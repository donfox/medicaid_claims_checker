# X12 837 test suite

Raw X12 files for testing ingestion and evaluation end to end, with the
expected result of each file in `manifest.json`. Patients and claims are
synthetic. Provider NPIs are real, from the NPPES registry the app imports,
so the NPPES cases (not found, deactivated, reactivated, service between
deactivation and reactivation) run against real registry records. The
deliberate exceptions are `1234567890` (fails the Luhn check),
`1999999992` (passes Luhn but is unassigned) and the malformed NPIs in the
format cases.

| Folder | What it covers |
|---|---|
| `files/single/` | One claim per file. Each active rule triggered on its own, NPPES outcomes (not found, deactivated, reactivated, service in the reactivation gap), and the exact $5, $5,000 and $50,000 thresholds |
| `files/formats/` | 837I and 837D, a file with no newlines, CRLF line endings, alternate delimiters |
| `files/multi/` | Several claims in one transaction set, several transaction sets, two claims under one subscriber |
| `files/errors/` | Truncated file, wrong SE count, mismatched control numbers, non-X12 text, a file too short to parse, an envelope with no claims |
| `files/zip/` | A zip holding `.x12`, `.edi`, `.json` and an ignored `.txt`; a zip entry named `../escape.x12` |
| `files/large/` | Not committed. 15,000 and 15,001-claim zips for the batch cap |

## Use

From `phoenix_web/`:

```sh
elixir test/fixtures/x12_suite/generate.exs                # rebuild files/ and manifest.json
elixir test/fixtures/x12_suite/generate.exs --large 15000  # add a large-batch zip

RULE_ENGINE_SECRET=... mix run --no-start test/scripts/verify_x12_suite.exs
mix run --no-start test/scripts/verify_x12_suite.exs --large test/fixtures/x12_suite/files/large/large_batch_15000.zip
```

The verifier needs the dev database (seeded rules plus an imported NPPES
registry) and, except with `--large`, the rule engine. It runs each file
through the steps a manual upload uses, then
the NPPES check and the engine with the active rules from the database.

Any file can also be uploaded on the Fetch Source page to check it by hand.

## Reading results

- `matched` lists exactly the rules that should match.
- `not_checked` lists rules that must come back "not checked". Others may too.
- Rules that aren't active in the database are left out of the comparison.
  Deactivating a rule doesn't break the suite, but a new or changed rule
  can change the expected results.
- A case marked `known_issue` records the correct behaviour that the current
  code doesn't yet produce. It reports XFAIL while the bug remains and XPASS
  once the bug is fixed. On XPASS, delete its `known_issue` in `generate.exs`.

Edit cases in `generate.exs`, never in `manifest.json` or the files, then regenerate.
