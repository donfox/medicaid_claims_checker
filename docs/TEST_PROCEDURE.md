# Test Procedure

This is the lean, day-to-day test workflow for local validation.

Detailed historical expected-output matrices are retained in `docs/archive/reviews/`.

## Prerequisites

- Haskell toolchain (`stack` or `cabal`)
- Elixir + Mix
- PostgreSQL
- `curl` and `jq`

## 1. Unit Tests (No Services Required)

### Haskell

```bash
cd haskell_engine
stack test
```

Alternative:

```bash
cd haskell_engine
cabal test --test-show-details=direct
```

Pass criteria: no failing specs/properties.

### Phoenix/Elixir

```bash
cd phoenix_web
mix test
```

Pass criteria: `0 failures`.

## 2. Start Services

From project root:

```bash
./start.sh -f
```

Or run separately:

```bash
cd haskell_engine && cabal run medicaid-claims-dsl-exe
cd phoenix_web && mix phx.server
```

Health checks:

```bash
curl -s http://localhost:8080/api/health | jq .
curl -s http://localhost:4000/api/health
```

Pass criteria: Haskell returns `{"status":"healthy"}` and Phoenix returns HTTP 200.

## 3. Integration Scripts

From `phoenix_web`:

```bash
bash test/scripts/run_tests.sh
bash test/scripts/run_faulty_tests.sh
bash test/scripts/test_integration.sh
```

What they validate:

- DSL parse success for valid rules
- DSL parse failure for intentionally broken rules
- End-to-end compile + batch evaluate behavior

Pass criteria: each script exits 0.

## 4. API Smoke Checks

Use these key endpoint checks:

- `POST /api/parse-rule` for parse-only validation
- `POST /api/evaluate` for one-claim decision behavior
- `POST /api/batch-evaluate` for batch behavior
- `POST /api/check-redundancy` for duplicate/subsumption/overlap detection

Use payload fixtures from `phoenix_web/test/fixtures/` where possible.

## 5. UI Functional Smoke

At `http://localhost:4000/rules`, verify:

- Catalogue loads and entries are selectable
- Default rules are read-only
- BA rules can be edited and saved
- ML model entries are read-only
- New BA rule can be created and appears in the catalogue

Also check `http://localhost:4000/catalogue` renders correctly.

## 6. Negative Cases

Verify API returns clear errors for:

- Unsupported `contract_version`
- Missing required fields
- Empty `tenant_id`
- Malformed DSL input

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

- Unit tests pass (`stack test`, `mix test`)
- Both services healthy
- Integration scripts exit 0
- Core API endpoints behave correctly
- UI rule workflows work end to end
