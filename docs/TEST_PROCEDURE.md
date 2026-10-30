# Test Procedure

This is the practical day-to-day workflow for local validation.

Detailed historical expected-output matrices and older review materials are retained in `docs/archive/reviews/`.

## Prerequisites

Make sure the following are available locally:

- Haskell toolchain (`stack` or `cabal`)
- Elixir and Mix
- PostgreSQL
- `curl`
- `jq`

## 1. Run Unit Tests

These tests do not require both services to be running.

### Haskell

```bash
cd haskell_engine
stack test
```

Besides the unit tests (one file per engine module under `test/Claims/`), this
checks that every rule in `test/fixtures/valid_rules.dsl` parses and every rule in
`test/fixtures/faulty_rules.dsl` is rejected.

Alternative:

```bash
cd haskell_engine
cabal test --test-show-details=direct
```

**Pass criterion:** no failing specs or properties.

### Phoenix / Elixir

```bash
cd phoenix_web
mix test
```

**Pass criterion:** `0 failures`.

## 2. Start the Services

From the project root:

```bash
./start.sh -f
```

Or run each service separately:

```bash
cd haskell_engine && cabal run medicaid-claims-dsl-exe
cd phoenix_web && mix phx.server
```

## 3. Run Health Checks

```bash
curl -s http://localhost:8080/api/health | jq .
curl -s http://localhost:4000/api/health
```

**Pass criterion:**

- Haskell returns `{"status":"healthy"}`
- Phoenix returns HTTP `200`

## 4. Run the Use-Case Tests

### Use-case tests (the frontend, end to end)

From the repo root:

```bash
./test.sh            # every use case
./test.sh R5 N7      # only these use cases
```

Each test uploads a `mock_data` file through the home page's Manual Upload form (or
enters a rule on the Rules page), the real engine evaluates it against the seeded
business rules, and the result is checked against `mock_data/manifest.json`. The
tests live in `phoenix_web/test/use_cases/`, one file per group, each test tagged
with its use-case ID. `test.sh` starts its own engine on port 8092 (another with
`TEST_ENGINE_PORT=...`) and stops it afterwards, so a running `./start.sh` is left
alone. The tests use the test database, with the registry rows for the mock data's
NPIs loaded from `mock_data/nppes_extract.json`, so the dev database is untouched.

A plain `mix test` skips them (they need the engine).

**Pass criterion:** `0 failures`.

### Mock data

All test data is in `mock_data/`, one folder per use case (see `mock_data/README.md`).
From `phoenix_web`, with the engine running and the dev database seeded:

```bash
mix run --no-start ../mock_data/verify.exs            # every generated file
mix run --no-start ../mock_data/verify.exs --only R5  # one use case
```

Each file goes through the same steps as an upload, then the NPPES check and the active
rules, and the outcome is compared with `mock_data/manifest.json`.

**Pass criterion:** no `FAIL` lines.

### Uploading test data more than once

Phoenix refuses a file or a claim it has already received ("Clear display" doesn't
reset this). In development, the Manual Upload box "Test upload: allow re-submission"
(ticked by default) lets the same files be uploaded again. The scripts above don't
upload, so they can run any number of times. To upload copies under new claim IDs
instead (ending in `-N`, with a new N each round):

```bash
elixir mock_data/retag.exs --tag 3 --out ~/upload_round3 mock_data
```

Files without claims (the X12 error cases) are never recorded, so they can be uploaded
again as they are.

## 5. Run API Smoke Checks

Validate these core endpoints:

- `POST /api/parse-rule` — parse-only validation
- `POST /api/evaluate` — one-claim decision behavior
- `POST /api/batch-evaluate` — multi-claim batch behavior
- `POST /api/check-redundancy` — duplicate, subsumption, and overlap detection

Use the claims and rule files in `mock_data/` (see `mock_data/README.md`) whenever possible.

## 6. Run UI Functional Smoke Checks

At `http://localhost:4000/rules`, verify that:

- the catalogue loads and entries are selectable
- default rules are read-only
- BA rules can be edited and saved
- ML model entries are read-only
- a new BA rule can be created and appears in the catalogue

Also verify that `http://localhost:4000/catalogue` renders correctly.

## 7. Check Negative Cases

Confirm that the API returns clear errors for:

- unsupported `contract_version`
- missing required fields
- empty `tenant_id`
- malformed DSL input

## 7. Latest Batch NPI/NPPES Audit

Use this to verify provider NPI presence and NPPES status for the latest ingested batch,
including scheduled remote fetch batches.

From `phoenix_web`:

```bash
psql -P pager=off medicaid_claims_checker_dev -f ../docs/scripts/latest_batch_npi_nppes_audit.sql
```

What it reports:

- latest batch metadata (`batch_id`, source, status)
- filename and service date
- rendering and billing NPIs from `raw_claim_json`
- whether each NPI exists in `nppes_providers`
- whether each NPI is active on the service date

### Audit a Specific Batch ID

If you want to inspect a specific historical batch:

```bash
psql -P pager=off -v batch_id=560 medicaid_claims_checker_dev -f ../docs/scripts/batch_npi_nppes_audit.sql
```

Replace `560` with the target DB batch id from the `batches` table.

## Quick Checklist

Use this list as the final go/no-go check:

- Unit tests pass: `stack test` and `mix test`
- Both services report healthy
- Integration scripts exit `0`
- Core API endpoints behave correctly
- UI rule workflows work end to end
