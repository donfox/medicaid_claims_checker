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

## 4. Run Integration Scripts

From `phoenix_web`:

```bash
bash test/scripts/run_tests.sh
bash test/scripts/run_faulty_tests.sh
bash test/scripts/test_integration.sh
```

### What these scripts validate

- DSL parse success for valid rules
- DSL parse failure for intentionally broken rules
- End-to-end compile and batch-evaluate behavior

**Pass criterion:** each script exits with status `0`.

## 5. Run API Smoke Checks

Validate these core endpoints:

- `POST /api/parse-rule` — parse-only validation
- `POST /api/evaluate` — one-claim decision behavior
- `POST /api/batch-evaluate` — multi-claim batch behavior
- `POST /api/check-redundancy` — duplicate, subsumption, and overlap detection

Use payload fixtures from `phoenix_web/test/fixtures/` whenever possible.

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

## Quick Checklist

Use this list as the final go/no-go check:

- Unit tests pass: `stack test` and `mix test`
- Both services report healthy
- Integration scripts exit `0`
- Core API endpoints behave correctly
- UI rule workflows work end to end
