# Medicaid Claims Checker - Architecture

## System Overview

The system has two runtime services:

- Phoenix LiveView frontend on port 4000
- Haskell DSL engine on port 8080

The frontend sends rule text + claim payloads to the backend over HTTP/JSON for parsing and evaluation.

## Backend API Surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET | Liveness check |
| `/api/parse-rule` | POST | Parse DSL text and return AST/errors |
| `/api/evaluate` | POST | Evaluate rules against one claim payload |
| `/api/batch-evaluate` | POST | Evaluate one ruleset against many claim payloads |
| `/api/compile-rules` | POST | Parse a full ruleset, cache ASTs, return preflight counts |

## Core Engine Modules

- `Syntax.hs`: DSL AST, shared core types, and evaluation result types
- `Parser.hs`: Parsec parser (`RULE ... END` and shorthand form)
- `SimpleEvaluator.hs`: JSON-first predicate evaluator used by UI/API flows
- `RuleEngine.hs`: multi-rule orchestration and reporting
- `RuleCache.hs`: thread-safe STM cache of parsed rule ASTs, keyed by rule name
- `PolicyCombiner.hs`: merges DSL results with ML scoring into a combined policy envelope
- `RedundancyChecker.hs`: detects redundant rules (exact duplicates, condition overlap, subsumption)
- `MLClient.hs`: HTTP client for external ML scoring service
- `Main.hs`: WAI/Warp HTTP server and endpoint handlers

## Primary Data Flows

### Evaluate Flow

1. Frontend submits `rulesText` + claim payload to `/api/evaluate`
2. Backend parses rules and evaluates predicates/actions
3. Backend returns evaluation report (and combined policy envelope where configured)

### Preflight / Cache Flow

1. Frontend submits `rulesText` to `/api/compile-rules`
2. Backend parses all rules and caches ASTs in the STM rule cache
3. Backend returns parse success status and rule count

## Design Constraints

- Deterministic DSL behavior remains policy source of truth
- JSON payload evaluation is the primary active path
- Compiled rule cache is process-local and thread-safe (STM)
- Module namespace is `Claims.*` (retained from original X12 EDI scope; now JSON-first)

## Operational Notes

- Current setup assumes trusted/internal usage
- For production hardening: add auth, rate-limits, TLS, and durable audit logging

## Related Docs

- DSL authoring: `SYNTAX_GUIDE.md`
- Data model: `DATABASE_ERD.md`
- ML + DSL contract: `ML_DSL_POLICY_CONTRACT.md`
