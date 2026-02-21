# JSON Claims Integrity - Architecture

## System Overview

The system has two runtime services:

- Phoenix LiveView frontend on port 4000
- Haskell DSL engine on port 8080

The frontend sends rule text + claim payloads to the backend over HTTP/JSON for parsing, evaluation, and compilation operations.

## Backend API Surface

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET | Liveness check |
| `/api/parse-rule` | POST | Parse DSL text and return AST/errors |
| `/api/evaluate` | POST | Evaluate rules against one claim payload |
| `/api/batch-evaluate` | POST | Evaluate one ruleset against many claim payloads |
| `/api/compile-rules` | POST | Compile a full ruleset and cache successful rules |
| `/api/compile-rule` | POST | Compile one rule and return generated source |
| `/api/evaluate-compiled` | POST | Evaluate with a previously compiled rule |
| `/api/compiled-rules` | GET | List compiled-rule cache entries |

## Core Engine Modules

- `Syntax.hs`: DSL AST and shared core types
- `Parser.hs`: Parsec parser (`RULE ... END` and shorthand form)
- `SimpleEvaluator.hs`: JSON-first predicate evaluator used by UI/API flows
- `Evaluator.hs`: typed legacy evaluator path
- `RuleEngine.hs`: multi-rule orchestration and reporting
- `Compiler.hs`: AST-to-Haskell generation + GHC compile validation
- `Main.hs`: WAI/Warp HTTP server and endpoint handlers

## Primary Data Flows

### Evaluate Flow

1. Frontend submits `rulesText` + claim payload to `/api/evaluate`
2. Backend parses rules and evaluates predicates/actions
3. Backend returns evaluation report (and combined policy envelope where configured)

### Compile Flow

1. Frontend submits rule text to `/api/compile-rule`
2. Backend parses rule, generates standalone Haskell source
3. Backend validates source via `stack exec -- ghc -c`
4. Backend returns compile status + generated source

## Design Constraints

- Deterministic DSL behavior remains policy source of truth
- JSON payload evaluation is the primary active path
- Compiled rule cache is process-local and thread-safe (STM)
- Internal naming still includes legacy `X12` module prefixes

## Operational Notes

- Current setup assumes trusted/internal usage
- For production hardening: add auth, rate-limits, TLS, and durable audit logging

## Related Docs

- DSL authoring: `SYNTAX_GUIDE.md`
- Data model: `DATABASE_ERD.md`
- ML + DSL contract: `ML_DSL_POLICY_CONTRACT.md`
