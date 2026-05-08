# Code Evaluation: medicaid_claims_checker
**Evaluation Date:** April 22, 2026  
**Scope:** Full source review — Haskell DSL engine + Phoenix LiveView frontend

---

## Executive Summary

This is a well-architected, thoughtfully documented two-service application consisting of a custom fraud-detection DSL engine in Haskell and a Phoenix/Elixir web frontend. The code quality is genuinely strong for a project at this stage. As a **proof-of-concept or internal tool**, it is ready. As a **production system handling Medicaid PHI (Protected Health Information)**, it has several blocking gaps — primarily around authentication, HIPAA-grade transport security, and a silent ML fallback — that must be addressed before go-live. None of these are architectural rewrites; they are additions.

**Overall verdict:**

| Target | Status |
|---|---|
| Proof of concept / internal demo | ✅ Ready |
| Production (internal, non-PHI) | ⚠️ Near-ready (5–7 fixes) |
| Production (Medicaid / HIPAA scope) | ❌ Blocked — auth + TLS required |

---

## Architecture Overview

The system has two runtime processes:

- **Haskell WAI/Warp engine** (port 8080) — parses the custom fraud-detection DSL, evaluates rules against JSON claim payloads, runs rule redundancy checks, and calls an optional external ML scoring service. It exposes five JSON API endpoints.
- **Phoenix LiveView frontend** (port 4000) — ingests claims from manual uploads and scheduled fetch sources, performs in-app X12 translation to semantic JSON, persists data to PostgreSQL via Ecto, performs NPPES provider pre-validation, dispatches async evaluation tasks to the Haskell engine, and displays results in real time via PubSub + LiveView.

The separation of concerns is clean. The DSL engine is stateless and pure except for an STM rule cache and optional ML HTTP calls. The Phoenix layer owns all persistence, supervision, and real-time UI concerns. This is a good architectural split.

---

## Strengths

**Haskell engine**
- The DSL is genuinely rich: comparisons, BETWEEN ranges, IS NULL/NOT NULL, EXISTS/FORALL quantifiers with optional named variables, COUNT, helper functions (is_weekend, is_valid_npi, is_future_date, etc.), and composite actions. The grammar is clean and well-documented with Haddock.
- The Parsec parser handles operator precedence correctly (OR < AND < NOT < atomic). Keyword boundary detection via `notFollowedBy` prevents partial matches like "ANDROID" being read as "AND" + "ROID".
- `RedundancyChecker.hs` implements four distinct levels of rule conflict detection (exact duplicate, subsumption, shadowing, field-range overlap), including conservative predicate implication reasoning. This is sophisticated.
- `PolicyCombiner.hs` has a clean priority-ordered decision matrix (DSL reject → ML error fallback → ML threshold routing). The logic is transparent and the thresholds are configurable through `PolicyConfig`.
- The STM-based `RuleCache` is correctly thread-safe. `TVar` with `atomically` is exactly right here.
- NPI Luhn-10 validation using the CMS health-industry prefix `[8, 0, 8, 4, 0]` is correct per CMS specification.
- All modules are well-documented. Haddock comments are thorough without being excessive.

**Phoenix/Elixir layer**
- `ingest_batch/1` wraps all DB writes in a single `Repo.transaction/1`, which correctly rolls back on partial failure.
- Async batch evaluation uses `Task.Supervisor.start_child`, giving each evaluation job OTP supervision with crash isolation from the web process.
- NPPES pre-validation before sending to the Haskell engine is a sound design: it hard-rejects claims with invalid/deactivated provider NPIs without burning rule engine capacity.
- `validate_claim_providers/1` extracts the earliest service date and checks both rendering and billing NPIs. Date parsing handles both ISO 8601 (`2026-03-10`) and compact (`20260310`) formats.
- `broadcast_completed/1` enriches the PubSub event with per-file risk and matched-rule details, giving the LiveView UI enough context to render without extra DB queries.
- `find_similar_catalogue_entries/1` using Jaro distance (> 0.85) for fuzzy name matching is a nice usability touch for the rule catalogue.

---

## Issues by Severity

### 🔴 Blocking for Production

**1. No authentication on either service**

Neither the Phoenix API routes nor the Haskell WAI server requires any authentication. Claim ingestion and evaluation endpoints can be reached by any caller with network access. The Haskell engine will evaluate rules for any process that can reach port 8080. The `ARCHITECTURE.md` explicitly acknowledges this: *"Current setup assumes trusted/internal usage."* For a Medicaid application this is a hard blocker — 45 CFR § 164 requires access controls on PHI.

Minimum fix: add Phoenix plug authentication (API key or mTLS) on the ingest endpoint, and either network-isolate the Haskell engine behind the Phoenix layer or add a shared secret header check.

**2. No HTTPS enforcement in production config**

`config/prod.exs` has no `force_ssl: [hsts: true]` directive, and `runtime.exs` only configures the HTTP listener. PHI must be encrypted in transit under HIPAA. This is a two-line addition to the endpoint config.

**3. ML fallback silently uses a fixed stub score in production**

`fetchOrStub/2` in `Main.hs` falls back to `mlStubResult` (a hardcoded risk score of `0.42`, confidence `0.74`) whenever `ML_SCORER_URL` is not set. There is no log warning, no flag in the response, and no indication to the caller that the ML result is fake. In production this would allow claims to slip through with a deterministic, always-medium-risk fake score without anyone knowing the ML system was offline. Either fail loudly, or mark stub results with an `ml_mode: "stub"` field in the audit section of the envelope.

**4. Unlimited `Task.Supervisor` concurrency**

`Task.Supervisor.start_child` is called for every ingested batch with no concurrency cap. Under load — or if an attacker deliberately floods the ingest endpoint — this can create an unbounded number of concurrent Haskell HTTP calls and DB transactions, exhausting the connection pool and CPU. Add a `max_children` guard or use a pooled task approach.

---

### 🟠 High Severity

**5. `ensure_manual_batch_table/0` has a race condition**

The `:ets.whereis/1` → `:ets.new/2` sequence is not atomic. In a multi-process or cluster scenario, two processes could simultaneously see `:undefined` and both attempt to create the named table, causing one to crash. Use `:ets.new(:manual_upload_batches, [:set, :public, :named_table])` inside a `try/rescue` to handle the already-exists case, or gate it behind an Application start callback. The entire ETS-based approach also breaks in a multi-node cluster — the table is node-local while batch ingestion could arrive at any node.

**6. `HighRisk` claims labeled `"fraudulent"` in the database**

In `evaluate_with_engine/3`, the status is set to `"fraudulent"` when `risk in ["CriticalRisk", "HighRisk"]`. `HighRisk` (3+ rules with risk score ≥ 70) is a fraud indicator, not a confirmed fraud determination. Labeling it `"fraudulent"` has legal and operational implications in a Medicaid context. Consider a separate `"high_risk"` or `"requires_review"` status for `HighRisk`, reserving `"fraudulent"` for `CriticalRisk` (explicit flag/reject actions).

**7. Silent `Matches` predicate always returns `False`**

`SimpleEvaluator.hs` has `Syntax.Matches _ _ -> False -- TODO: Implement regex matching`. The DSL parser accepts `Matches` predicates, they compile, and rules using them silently never trigger. A rule author would have no idea their regex predicate is a no-op. At minimum, log a warning or return an error result rather than silently returning false.

**8. `showThreshold` in `PolicyCombiner.hs` hardcodes doubles**

```haskell
showThreshold d
  | d == 0.35 = "0_35"
  | d == 0.80 = "0_80"
  | d == 0.93 = "0_93"
  | otherwise = "custom"
```

If `PolicyConfig` thresholds are ever tuned (which they will be), the reason codes silently become `"ML:risk_lt_custom"` instead of reflecting the actual value. Use `T.replace "." "_" (T.pack (printf "%.2f" d))` or similar.

**9. `validate_claim_providers` passes claims with no NPI**

When both `provider.npi` and `billing_provider.npi` are absent, `npis == []` returns `:ok`. This means a claim with no provider information bypasses NPI validation entirely and proceeds to DSL evaluation. For Medicaid billing, every claim should have at least one NPI. Returning a rejection for no-NPI claims is safer.

**10. `$>` redefinition in `Parser.hs`**

```haskell
($>) :: (Functor f) => f a -> b -> f b
($>) = flip (<$)
```

`($>)` has been exported from `Data.Functor` since base 4.7 (GHC 7.8, 2014). This definition will produce a name-clash warning on current GHC and will become an error if `NoImplicitPrelude` or explicit Prelude imports are used. Remove the local definition and import `($>)` from `Data.Functor`.

---

### 🟡 Medium Severity

**11. `numberLiteral` and `intLiteral` use partial `read`**

```haskell
numberLiteral = do
  ...
  pure $ read $ maybe intPart ((intPart ++ ".") ++) fracPart

intLiteral = read <$> many1 digit
```

`read` on malformed or overflow-inducing input throws a runtime exception that Parsec will not catch, turning a parse error into an unhandled exception. Use `readMaybe` and fail with a meaningful parse error.

**12. No request body size limits**

Neither the Haskell WAI server nor Phoenix enforces a maximum request body size. The batch ingest endpoint could receive a payload with thousands of claims and gigabytes of JSON. Set a reasonable limit (e.g., 10 MB) via Plug.Parsers `:length` option on the Phoenix side and a WAI body size wrapper on the Haskell side.

**13. String escape sequences not supported in DSL**

`stringLiteral` in `Parser.hs` uses `many (noneOf "\"")`, which means double-quote characters cannot appear inside string values. A rule like `reason = "Provider said \"no\""` would silently truncate at the first inner quote. This is documented in a comment but is a real limitation for production rule authoring.

**14. `clear_batch_history/0` is a destructive public function**

`Claims.clear_batch_history/0` calls `Repo.delete_all(EdiFile)` and `Repo.delete_all(Batch)` — wiping all records. It's a public context function with no confirmation, no soft-delete, and no audit trail. For a production Medicaid system, hard-deleting claim records may violate retention requirements. Gate it behind a feature flag or remove it from the public API.

**15. `helperCallPred` accepts reserved keywords as function names**

In `Parser.hs`, `helperCallPred` parses `identifier` which does check for reserved keywords — but `bindingIdentifier` has its own keyword list that is slightly different from `identifier`'s list. The two lists should be kept in sync or merged into a single constant. A discrepancy means a keyword valid in one context might fail silently in another.

**16. Rule-to-engine status coupling via string comparison**

In `evaluate_with_engine/3`:
```elixir
if risk in ["CriticalRisk", "HighRisk"]
```
This couples the Phoenix layer to the exact string values produced by the Haskell engine's `show (reportOverallRisk report)`. If the Haskell `RiskLevel` constructors are ever renamed, this silently breaks. Consider defining a shared contract constant or using pattern matching against an agreed-upon set of values with a catch-all warning.

---

### 🟢 Minor / Good to Address

**17. No CI configuration**

No CI pipeline configuration was found. For a project with both Haskell (Stack) and Elixir (Mix) components plus integration between them, a CI pipeline that runs `stack test` and `mix test` on every push would have significant value. `ParserProps.hs` (13 KB, property-based tests) and `Spec.hs` (51 KB) represent real investment in testing — that investment is undermined without automated CI.

**18. No database indexes declared in migrations**

Looking at the migration filenames, the schema has `edi_files.batch_id` (FK) and `batches.batch_id` (unique string). Ecto unique constraints create a unique index, but the FK column `edi_files.batch_id` should have a plain index for the frequent `WHERE batch_id = ?` queries in `list_files_for_batch/1`. Confirm this is covered in the migrations; if not, add it.

**19. `default_batch_name` timezone dependency**

`format_eastern_timestamp/0` calls `DateTime.shift_zone!("America/New_York")`. This requires the `tzdata` dependency to have up-to-date timezone data. The `tzdata` package auto-downloads updates, which may fail in air-gapped production environments. Ensure the IANA timezone database is bundled in the release.

**20. PHI potentially in logs**

`Logger.info("Batch #{batch.batch_id} ingested ...")` and `Logger.error("Batch evaluation failed for #{batch.batch_id}: #{inspect(reason)}")` log batch identifiers and error details. In the Haskell engine, `show err` on a `SomeException` may include claim field values. Under HIPAA, log output containing PHI requires the same access controls as the data itself. Audit all logger calls and ensure they log only technical identifiers, never claim content.

---

## Test Coverage Assessment

| Area | Evidence |
|---|---|
| Haskell parser | `ParserProps.hs` — QuickCheck property-based tests |
| Haskell engine / evaluator | `Spec.hs` (~51 KB) — substantial HSpec suite |
| Elixir evaluator | `evaluator_test.exs` (~12 KB) |
| Elixir claims context | `claims_test.exs` (~5.5 KB) |
| Controller | `x12_batch_ingest_controller_test.exs` |
| Batch integration | `test_e2e_batch_ingest.sh` shell script |

Test coverage is meaningfully above average for a project at this stage. The property-based Haskell tests are particularly valuable for parser correctness. The main gaps are: no tests for the ML fallback behavior, no tests for `validate_claim_providers` edge cases (missing NPI, deactivated provider), and no CI to keep them green.

---

## Prioritized Remediation Roadmap

**Before any production deployment:**

1. Add API key or mTLS authentication to the Phoenix ingest endpoint and either isolate or authenticate the Haskell engine port
2. Add `force_ssl: [hsts: true]` to the Phoenix endpoint configuration
3. Make the ML stub fail loudly (warning log + audit flag) when `ML_SCORER_URL` is not set
4. Add a concurrency limit to `Task.Supervisor.start_child` batch evaluation

**Before go-live with real Medicaid data:**

5. Fix `ensure_manual_batch_table` race condition; migrate away from ETS for cluster safety
6. Separate `HighRisk` from `CriticalRisk` in the `edi_files.status` domain
7. Return an explicit error or warning for `Matches` predicates instead of silent `False`
8. Fix `showThreshold` to use a computed string rather than hardcoded match patterns
9. Reject claims with no provider NPI in `validate_claim_providers`
10. Audit all `Logger` calls for PHI leakage

**Cleanup / hardening:**

11. Remove `$>` redefinition in `Parser.hs`; use `Data.Functor.($>)`
12. Replace `read` with `readMaybe` in number literal parsers
13. Add request body size limits on both services
14. Gate or remove `clear_batch_history/0`
15. Add CI pipeline for both Stack and Mix test suites
16. Confirm or add `edi_files.batch_id` DB index

---

## Summary

The `medicaid_claims_checker` codebase demonstrates real engineering depth. The Haskell DSL engine — parser, evaluator, redundancy checker, policy combiner, ML client — is cleanly designed and well-tested. The Phoenix layer correctly uses OTP supervision, database transactions, and PubSub. The documentation is thorough. This is not a throwaway prototype.

The gap between "strong POC" and "production-ready" is narrower than it might appear from the list above. The blocking items (authentication, TLS, ML stub warning, concurrency cap) are additions, not rewrites. The medium items are mostly defensive improvements to an already sound foundation. A focused two-to-three week hardening sprint could bring this to production readiness for an internal or pilot deployment — with a longer runway needed for full HIPAA compliance documentation, audit logging, and role-based access controls.
