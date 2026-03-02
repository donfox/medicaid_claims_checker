# JSON Claims Integrity DSL Engine

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
- Redundancy detection across rule sets (exact duplicate, condition overlap, subsumption)

## Module Overview

| Module | Purpose |
|---|---|
| `X12.DSL.Syntax` | AST types for rules, predicates, actions, field references, and evaluation results |
| `X12.DSL.Parser` | Parsec-based DSL parser |
| `X12.DSL.SimpleEvaluator` | Evaluate predicates against generic JSON claim payloads |
| `X12.DSL.RuleCache` | Thread-safe STM cache of parsed rule ASTs, keyed by rule name |
| `X12.DSL.RuleEngine` | Multi-rule evaluation engine and reporting |
| `X12.DSL.PolicyCombiner` | Merge DSL results with ML scoring into a combined policy envelope |
| `X12.DSL.RedundancyChecker` | Detect redundant rules: exact duplicates, condition overlap, and subsumption |
| `X12.DSL.MLClient` | HTTP client for calling the external ML scoring service |
| `X12.DSL.EvaluationContract` | Request/response types for the evaluation API |

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

The UI displays two metrics per evaluated claim under **Fraud Detection Details**:

### Rule-Based Score

Shows the ratio of matched (triggered) rules to total rules evaluated, e.g. `3 / 17`. The bar fills proportionally. This answers: **how many rules fired?**

### Overall Risk Assessment

A severity classification (0-100 scale) derived from the *actions* of the matched rules, not just the count. This answers: **how bad are the rules that fired?**

The `determineRiskLevel` function in `RuleEngine.hs` computes the level:

| Level | Score | Condition |
|---|---|---|
| CriticalRisk | 90 | Any matched rule triggers `RejectClaim` or `FlagFraud` |
| HighRisk | 65 | 3+ matched rules have `AssignRiskScore >= 70` |
| MediumRisk | 35 | 1-2 matched rules have `AssignRiskScore >= 70` |
| LowRisk | 5 | No high-severity actions |

A claim can trigger many rules but remain LowRisk if they are all low-severity. Conversely, a single `REJECT` match produces CriticalRisk.

## Parse and Cache Pipeline

```
DSL Text  -->  Parser  -->  Rule AST  -->  RuleCache  -->  evaluateRuleSimple
```

Rules are parsed once per request (or pre-cached via `/api/compile-rules`) and evaluated directly against JSON claim payloads using `SimpleEvaluator`. No Haskell code generation or GHC invocation.

## License

Proprietary — All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root LICENSE file for full terms.
