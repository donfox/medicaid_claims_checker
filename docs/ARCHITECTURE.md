# Medicaid Claims Checker Architecture

This document describes the **current active architecture**. Historical analysis and older review artifacts live under `docs/archive/`.

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
| `/api/compile-rules` | POST | Parse a ruleset and warm the in-memory rule cache |
| `/api/check-redundancy` | POST | Detect duplicate, overlapping, or subsuming rules |

## Core Engine Modules

| Module | Responsibility |
|---|---|
| `Syntax.hs` | DSL AST and shared rule/result types |
| `Parser.hs` | Parsec grammar for `RULE ... END` and shorthand syntax |
| `SimpleEvaluator.hs` | Predicate and action evaluation against JSON claims |
| `RuleEngine.hs` | Rule orchestration and report aggregation |
| `RuleCache.hs` | STM-based cache of parsed rules |
| `PolicyCombiner.hs` | DSL + ML policy merge logic |
| `RedundancyChecker.hs` | Rule redundancy analysis |
| `MLClient.hs` | Optional ML scoring client |
| `Main.hs` | HTTP routing and request handlers |

## Primary Flows

### 1. Rule Evaluation

1. A client posts `rulesText` and one or more claim payloads to `/api/evaluate` or `/api/batch-evaluate`.
2. The engine parses the rules, evaluates predicates and actions, and computes the overall decision and risk.
3. The engine returns a structured JSON response for the UI and downstream handling.

### 2. Preflight and Caching

1. A client posts `rulesText` to `/api/compile-rules`.
2. The engine parses the rules and stores the AST in a process-local STM cache.
3. The response returns parse status plus the compiled-rule count.

### 3. Scheduled X12 Ingestion Pipeline

1. A Quantum scheduler triggers a `FetchRunner` job when a `fetch_schedules` entry is due.
2. `RemoteFetcher` downloads files from the configured `fetch_sources` URI using SFTP or HTTPS.
3. `ClaimSplitter` splits multi-claim X12 files, and `Converter` plus `SegmentMapper` translate each claim into semantic JSON.
4. `Claims.ingest_batch/1` writes one `batches` row and one `edi_files` row per claim in a single transaction.
5. After a successful ingest, `Task.Supervisor` starts `Evaluator.evaluate_batch/1` asynchronously.

### 4. Batch Evaluation with NPPES Pre-validation

1. `Evaluator` collects all active BA rule text and the translated `edi_files` for the batch.
2. Before rule evaluation, `Claims.validate_claim_providers/1` checks each claim's provider NPI against `nppes_providers`.
3. Invalid NPIs generate an `NPPESProviderLookup` rejection finding.
4. Claims are chunked into groups of `200` and sent to the Haskell `/api/batch-evaluate` endpoint sequentially with `Enum.reduce_while`.
5. NPPES findings are merged into each Haskell result, and any NPI rejection forces `overallRisk` to `CriticalRisk`.
6. Results are written back to `edi_files`, and the batch status is updated to `completed` or `failed`.
7. Phoenix PubSub broadcasts `batch_completed` or `batch_failed` to the LiveView UI.

### 5. NPPES Data Refresh

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
- The rule cache is in memory and process-local on the Haskell side.
- Only `/api/compile-rules` populates the rule cache.
- `/api/batch-evaluate` reparses rules on every request.
- Batch evaluation uses a hardcoded chunk size of `200` claims per Haskell request.
- Claims inside a single Haskell request are evaluated sequentially.
- Larger batches therefore become CPU-bound.
- NPPES data is refreshed on an interval, so claims evaluated between refreshes use the most recently imported snapshot.
- The current deployment model assumes a trusted internal network.

## Concurrency Model and Scaling

### Current behavior

- Warp can handle concurrent HTTP requests across batches.
- Claims inside one batch request are evaluated **sequentially**.
- Rules inside a claim are also evaluated sequentially.
- The STM/TVar rule cache is thread-safe across concurrent requests.

### Main bottleneck

A large batch sent as one request becomes a sequential CPU bottleneck inside the Haskell engine.

### Recommended improvements not yet implemented

- **Bounded parallel claim evaluation** inside Haskell using a worker pool
- **GHC runtime tuning** with `+RTS -N` to use all available CPU cores
- **Phoenix backpressure** to limit concurrent in-flight Haskell requests to 1 or 2 at a time

### Production sizing model

| Layer | Setting | Why it matters |
|---|---|---|
| Phoenix chunk size | 100–500 claims | Keeps individual requests bounded |
| Phoenix concurrent batches | 1–2 | Prevents Haskell overload |
| Haskell workers per request | about 1 per core | Improves CPU utilization |

### Throughput estimates

- Approximately `30–120` claims per second, depending on rule complexity
- `10,000` claims may take:
  - `1–3 minutes` for lighter rules
  - `3–8 minutes` for heavier rules

**Core principle:** the system may accept large volumes of work, but the amount of work in active execution should stay bounded.

## Related Documents

- `SYNTAX_GUIDE.md` — DSL authoring guide
- `DATABASE_ERD.md` — data model and relationships
- `TEST_PROCEDURE.md` — local validation workflow
