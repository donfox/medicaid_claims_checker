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
| `/api/evaluate` | POST | Evaluate rules against a single claim |
| `/api/batch-evaluate` | POST | Evaluate rules against multiple claims |
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

## Current Constraints

- DSL rules are the deterministic policy source of truth.
- JSON claim evaluation is the primary active execution path.
- Rule cache is in-memory and process-local.
- Current deployment model assumes trusted/internal network usage.

## Related Docs

- DSL guide: `SYNTAX_GUIDE.md`
- Database model: `DATABASE_ERD.md`
- Test workflow: `TEST_PROCEDURE.md`
- Historical reviews: `archive/reviews/`
