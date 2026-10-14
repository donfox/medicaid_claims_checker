# Medicaid Claims Checker DSL Engine

Haskell-based engine for parsing, evaluating, and compiling fraud detection rules written in a domain-specific language for JSON claim payloads.

## Features

- Domain-Specific Language (DSL) for fraud detection rules
- Parser for business-analyst-friendly syntax
- Predicate evaluator for rule matching against JSON claim documents
- Parsed rule cache (thread-safe via STM)
- HTTP API server for rule parsing, evaluation, and preflight caching
- Support for complex predicates (AND, OR, NOT, EXISTS, FORALL, COUNT, BETWEEN)
- Named quantifier variables for nested quantifier correlation (`EXISTS x IN path WHERE ...`)
- Domain predicates (`claim.has_diagnosis`, `claim.has_procedure`)
- Text predicates: `CONTAINS` and `MATCHES` (POSIX regex via regex-tdfa — linear time, invalid patterns rejected at parse time)
- Pretty-printer that is the exact inverse of the parser, verified by QuickCheck round-trip properties
- Redundancy detection across rule sets (exact duplicate, condition overlap, subsumption)

## Module Overview

| Module | Purpose |
|---|---|
| `Claims.Syntax` | AST types for rules, predicates, actions, field references, and evaluation results |
| `Claims.Parser` | Parsec-based DSL parser |
| `Claims.Pretty` | Render rule ASTs back to DSL text; `parseRule . prettyRule` is the identity on parsed rules |
| `Claims.SimpleEvaluator` | Evaluate predicates against generic JSON claim payloads |
| `Claims.RuleCache` | Thread-safe STM cache of parsed rule ASTs, keyed by rule name |
| `Claims.RuleEngine` | Multi-rule evaluation engine and reporting |
| `Claims.PolicyCombiner` | Merge DSL results with ML scoring into a combined policy envelope |
| `Claims.RedundancyChecker` | Detect redundant rules: exact duplicates, condition overlap, and subsumption |
| `Claims.MLClient` | HTTP client for calling the external ML scoring service |
| `Claims.EvaluationContract` | Request/response types for the evaluation API |

## Building

Run from the `haskell_engine` directory:

```bash
stack build
```

From repository root, equivalent:

```bash
stack --stack-yaml haskell_engine/stack.yaml build
```

## Running

Run from the `haskell_engine` directory:

```bash
stack run
```

From repository root, equivalent:

```bash
stack --stack-yaml haskell_engine/stack.yaml run
```

The server starts on port 8080.

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/health` | GET | Health check |
| `/api/parse-rule` | POST | Parse DSL rule text and return AST |
| `/api/evaluate` | POST | Evaluate rules against a JSON claim payload |
| `/api/batch-evaluate` | POST | Evaluate one ruleset against many claim payloads |
| `/api/compile-rules` | POST | Parse a full ruleset, cache ASTs, return preflight counts |

## Fraud Detection Scoring

The UI shows, per evaluated claim under **Fraud Detection Details**, the number of rules triggered, a weighted score, the overall risk level, the triggered rules, and any rules that could not be checked.

### Overall risk level

A classification derived from the *actions* of the matched rules, not just their count. The `determineRiskLevel` function in `RuleEngine.hs` computes it, looking inside composite actions:

| Level | Condition |
|---|---|
| CriticalRisk | Any matched rule has `REJECT` or `FLAG_FRAUD` |
| HighRisk | Any matched rule has `REQUIRE_REVIEW`, or a `RISK_SCORE` of 70 or more |
| LowRisk | Anything else |

The app counts HighRisk and CriticalRisk claims as flagged for analyst review. `MediumRisk` is kept in the report format for stored reports but is not currently produced. A claim can trigger several rules and remain LowRisk if none of them asks for review or scores 70 or more.

### Rules not checked

A rule whose condition depends on missing or unusable data does not match. Its result has `resultUndecided: true`, the report's `undecidedRules` counts such rules, and the app lists them as not checked instead of calling the claim clean. See the Missing data section of `docs/SYNTAX_GUIDE.md`.

## Parse and Cache Pipeline

```
DSL Text  -->  Parser  -->  Rule AST  -->  RuleCache  -->  evaluateRuleSimple
```

Rules are parsed once per request (or pre-cached via `/api/compile-rules`) and evaluated directly against JSON claim payloads using `SimpleEvaluator`. No Haskell code generation or GHC invocation.

## License

Proprietary — All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root LICENSE file for full terms.
