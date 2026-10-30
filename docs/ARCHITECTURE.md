# Medicaid Claims Checker Architecture

How the two services fit together, what the engine's API offers, and how claims flow through the system.

## System Summary

The platform has two runtime services:

- **Phoenix LiveView app** on port `4000`  
  Handles the user interface, persistence, batch workflow, scheduling, and orchestration.
- **Haskell DSL engine** on port `8080`  
  Parses rules, evaluates claims, and returns deterministic rule decisions.

In normal operation, the Phoenix app sends rule text plus claim payloads to the Haskell engine over HTTP using JSON.

## Haskell API Surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET | Health and liveness check |
| `/api/parse-rule` | POST | Parse DSL text and return the parse result |
| `/api/evaluate` | POST | Evaluate rules against a single claim using the DSL + ML pipeline |
| `/api/batch-evaluate` | POST | Evaluate rules against multiple claims using the DSL only |
| `/api/check-redundancy` | POST | Detect duplicate, overlapping, or subsuming rules |

## Core Engine Modules

The engine's modules and what each does are listed in
[haskell_engine/README.md](../haskell_engine/README.md#module-overview).

## Primary Flows

### 1. Rule Evaluation

1. A client posts `rulesText` and one or more claim payloads to `/api/evaluate` or `/api/batch-evaluate`.
2. The engine parses the rules, evaluates predicates and actions, and computes the overall decision and risk.
3. The engine returns a structured JSON response for the UI and downstream handling.

### 2. Scheduled X12 Ingestion Pipeline

1. A Quantum scheduler triggers a `FetchRunner` job when a `fetch_schedules` entry is due.
2. `RemoteFetcher` downloads files from the configured `fetch_sources` URI using SFTP or HTTPS.
3. `ClaimSplitter` splits multi-claim X12 files, and `Converter` plus `SegmentMapper` translate each claim into semantic JSON.
4. `Claims.ingest_batch/1` writes one `batches` row and one `edi_files` row per claim in a single transaction. A file or claim already submitted is refused and recorded in `batches.duplicates`; manual uploads take the same path.
5. After a successful ingest, an Oban job (`Workers.BatchEvaluationWorker`) runs `Evaluator.evaluate_batch/1`.

### 3. Batch Evaluation with NPPES Pre-validation

1. `Evaluator` collects all active BA rule text and the translated `edi_files` for the batch.
2. Before rule evaluation, `Claims.validate_claim_providers/1` checks each claim's provider NPI against `nppes_providers`.
3. Invalid NPIs generate an `NPPESProviderLookup` rejection finding.
4. Claims are chunked into groups of `200` and sent to the Haskell `/api/batch-evaluate` endpoint sequentially with `Enum.reduce_while`.
5. NPPES findings are merged into each Haskell result, and any NPI rejection forces `overallRisk` to `CriticalRisk`.
6. Results are written back to `edi_files`, and the batch status is updated to `completed` or `failed`.
7. Phoenix PubSub broadcasts `batch_completed` or `batch_failed` to the LiveView UI.

### 4. NPPES Data Refresh

1. `Nppes.RefreshWorker` starts on application boot after a 10-second initial delay.
2. On each tick, it reads `nppes_refresh_config` and checks whether `interval_seconds` have elapsed since `last_refresh_at`.
3. The default refresh interval is `604800` seconds, or 7 days.
4. If a refresh is due, `Importer.download_and_import/2` runs under `Task.Supervisor` asynchronously.
5. Progress and completion status are broadcast through PubSub and persisted to `nppes_refresh_config`.
6. Refresh can also be started manually or cancelled through the `RefreshWorker` public API.

## Current Constraints

These are active design and implementation constraints, not future goals:

- DSL rules are the deterministic policy source of truth.
- JSON claim evaluation is the primary active execution path.
- `/api/batch-evaluate` reparses rules on every request; there is no rule cache.
- Batch evaluation uses a hardcoded chunk size of `200` claims per Haskell request, and a batch may hold at most 15,000 claims.
- The engine accepts 1,000 requests a minute per client IP by default (`ENGINE_RATE_LIMIT`).
- NPPES data is refreshed on an interval, so claims evaluated between refreshes use the most recently imported snapshot.
- Without a TLS certificate the engine listens on loopback only; serving it to another host requires HTTPS (see `haskell_engine/README.md`, "Listening and TLS").

## Concurrency Model

- **Engine:** the claims in one `/api/batch-evaluate` request are evaluated in
  parallel, on a worker pool with one slot per CPU core (the server runs with
  `+RTS -N`). Rules within a claim run one after another. Each claim has a
  30-second time limit.
- **Phoenix:** batch evaluations run as Oban jobs in the `batch_evaluation`
  queue, whose concurrency matches the engine's worker pool, so Phoenix never
  sends more concurrent batch requests than the engine can serve. Within one
  batch the 200-claim chunks are sent one after another.

The system may accept large volumes of work, but the work in active
execution stays bounded by the worker pool.

## Related Documents

- [SYNTAX_GUIDE.md](SYNTAX_GUIDE.md): writing business rules
- [DATABASE_ERD.md](DATABASE_ERD.md): the database tables
- [TEST_PROCEDURE.md](TEST_PROCEDURE.md): running the tests
