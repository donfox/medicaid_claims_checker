# Medicaid Claims Checker Architecture

This document describes the current, active architecture. Historical analysis reports live under `docs/archive/`.

## Runtime Services

- Phoenix LiveView app (port 4000): UI, persistence, batch workflow, and orchestration
- Haskell DSL engine (port 8080): parse/evaluate rules and return deterministic decisions

The Phoenix app sends rules plus claim payloads to the Haskell engine over HTTP/JSON.

## Haskell API Surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET | Service health/liveness |
| `/api/parse-rule` | POST | Parse DSL text and return parse result |
| `/api/evaluate` | POST | Evaluate rules against a single claim (DSL + ML pipeline) |
| `/api/batch-evaluate` | POST | Evaluate rules against multiple claims (DSL only, no ML) |
| `/api/compile-rules` | POST | Parse ruleset and warm rule cache |
| `/api/check-redundancy` | POST | Detect duplicates/subsumption/overlap among rules |

## Core Engine Modules

- `Syntax.hs`: DSL AST and shared rule/result types
- `Parser.hs`: Parsec grammar for `RULE ... END` and shorthand syntax
- `SimpleEvaluator.hs`: Predicate/action evaluation against JSON claims
- `RuleEngine.hs`: Rule orchestration and report aggregation
- `RuleCache.hs`: STM-based cache of parsed rules
- `PolicyCombiner.hs`: DSL + ML policy merge logic
- `RedundancyChecker.hs`: Rule redundancy analysis
- `MLClient.hs`: Optional ML scoring client
- `Main.hs`: HTTP routing and request handlers

## Primary Flows

### Rule Evaluation

1. Client posts `rulesText` and claim payload(s) to `/api/evaluate` or `/api/batch-evaluate`.
2. Engine parses rules, evaluates predicates/actions, and computes overall risk/decision.
3. Engine returns structured JSON results for UI and downstream handling.

### Preflight and Caching

1. Client posts `rulesText` to `/api/compile-rules`.
2. Engine parses and caches rule ASTs in a process-local STM cache.
3. Response returns parse status and compiled rule count.

### Scheduled X12 Ingestion Pipeline

1. Quantum scheduler fires a `FetchRunner` job when a `fetch_schedules` entry is due.
2. `RemoteFetcher` downloads files from the configured `fetch_sources` URI (SFTP or HTTPS).
3. `ClaimSplitter` splits multi-claim X12 files; `Converter` + `SegmentMapper` translate each claim to semantic JSON.
4. `Claims.ingest_batch/1` persists a `batches` record and one `edi_files` row per claim in a single transaction.
5. On successful ingest, `Task.Supervisor` launches `Evaluator.evaluate_batch/1` asynchronously.

### Batch Evaluation with NPPES Pre-validation

1. `Evaluator` gathers all active BA rule texts and the translated `edi_files` for the batch.
2. NPPES pre-validation: `Claims.validate_claim_providers/1` checks each claim's provider NPI against the `nppes_providers` table. Invalid NPIs produce a `NPPESProviderLookup` rejection finding.
3. Claims are chunked (200 per request) and sent to the Haskell `/api/batch-evaluate` endpoint in sequence via `Enum.reduce_while`.
4. NPPES findings are merged into each Haskell result; any NPI rejection forces `overallRisk` to `CriticalRisk`.
5. Results are written back to `edi_files`; batch status is updated to `completed` or `failed`.
6. Phoenix PubSub broadcasts `batch_completed` / `batch_failed` events to the LiveView UI.

### NPPES Data Refresh

1. `Nppes.RefreshWorker` GenServer starts on application boot with a 10-second initial delay.
2. On each tick it reads `nppes_refresh_config` and checks whether `interval_seconds` have elapsed since `last_refresh_at` (default interval: 604 800 s / 7 days).
3. If a refresh is due, `Importer.download_and_import/2` runs under `Task.Supervisor` (async, non-blocking).
4. Progress and completion status are broadcast via PubSub and persisted to `nppes_refresh_config`.
5. Refresh can also be triggered manually or cancelled via the `RefreshWorker` public API.

## Current Constraints

- DSL rules are the deterministic policy source of truth.
- JSON claim evaluation is the primary active execution path.
- Rule cache is in-memory and process-local (Haskell side); only `/api/compile-rules` populates it — `/api/batch-evaluate` re-parses rules on every request.
- Batch evaluation chunk size is 200 claims per Haskell request (hardcoded in `Evaluator`).
- Claims within each Haskell request are evaluated sequentially; large batches become CPU-bound.
- NPPES data is refreshed on an interval; claims evaluated between refreshes use the last imported snapshot.
- Current deployment model assumes trusted/internal network usage.

## Concurrency Model & Scaling

### Current behavior

- Warp handles concurrent HTTP requests across batches.
- Claims inside a single batch request are evaluated **sequentially** — no intra-request parallelism.
- Rules inside a claim are also evaluated sequentially.
- STM/TVar rule cache is thread-safe across concurrent requests.

### Bottleneck

Large batches sent as a single request become sequential CPU bottlenecks inside the Haskell engine.

### Recommended improvements (not yet implemented)

- **Bounded parallel claim evaluation** inside Haskell using a worker pool
- **GHC runtime tuning**: `+RTS -N` to use all available cores (e.g. `+RTS -N8` on an 8-core machine)
- **Phoenix backpressure**: limit concurrent in-flight Haskell requests to 1–2 at a time

### Production sizing model

| Layer | Setting | Rationale |
|---|---|---|
| Phoenix chunk size | 100–500 claims | Keeps individual requests bounded |
| Phoenix concurrent batches | 1–2 | Prevents Haskell overload |
| Haskell workers per request | ~1 per core | Maximises CPU utilisation |

### Throughput estimates

- ~30–120 claims/sec depending on rule complexity
- 10,000 claims: 1–3 minutes (light rules) / 3–8 minutes (heavy rules)

**Core principle:** accepted work can be large; active work must remain bounded.

## Related Docs

- DSL guide: `SYNTAX_GUIDE.md`
- Database model: `DATABASE_ERD.md`
- Test workflow: `TEST_PROCEDURE.md`
