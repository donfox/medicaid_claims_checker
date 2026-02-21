# JSON Claims Integrity DSL Engine

Haskell-based engine for parsing, evaluating, and compiling fraud detection rules written in a domain-specific language for JSON claim payloads.

## Features

- Domain-Specific Language (DSL) for fraud detection rules
- Parser for business-analyst-friendly syntax
- Predicate evaluator for rule matching against JSON claim documents
- GHC compilation pipeline: DSL rules are code-generated into self-contained Haskell modules and verified by GHC
- Compiled rule cache (thread-safe via STM)
- HTTP API server for rule parsing, evaluation, and compilation
- Support for complex predicates (AND, OR, NOT, EXISTS, FORALL, COUNT)

## Module Overview

| Module | Purpose |
|---|---|
| `X12.DSL.Syntax` | AST types for rules, predicates, actions, field references |
| `X12.DSL.Parser` | Parsec-based DSL parser |
| `X12.DSL.SimpleEvaluator` | Evaluate predicates against generic JSON claim payloads |
| `X12.DSL.Evaluator` | Evaluate predicates against typed legacy documents |
| `X12.DSL.Compiler` | Code generation (AST to Haskell source) and GHC compilation |
| `X12.DSL.RuleEngine` | Multi-rule evaluation engine |
| `X12.DSL.X12Types` | Shared document and result types (legacy naming) |

Note: module names under `X12.DSL.*` are retained for backward compatibility; current API/UI evaluation paths operate on JSON claim payloads.

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
| `/api/compile-rule` | POST | Generate Haskell source from a rule and compile with GHC |
| `/api/evaluate-compiled` | POST | Evaluate a document using a previously compiled rule |
| `/api/compiled-rules` | GET | List all compiled rules in the cache |

### Compile Rule

```bash
curl -X POST http://localhost:8080/api/compile-rule \
  -H 'Content-Type: application/json' \
  -d '{"ruleText": "RULE high_amount \"Flag high claims\" WHEN amount > 10000 THEN FLAG_FRAUD \"High amount\";"}'
```

Response includes the generated Haskell source, compilation status, and timing.

### Evaluate with Compiled Rule

```bash
curl -X POST http://localhost:8080/api/evaluate-compiled \
  -H 'Content-Type: application/json' \
  -d '{"ruleName": "high_amount", "document": {"amount": 25000}}'
```

## Compilation Pipeline

```
DSL Text  -->  Parser  -->  Rule AST  -->  Code Generator  -->  Haskell Source  -->  GHC Verification
                                                |
                                                +-- generateRuleCode: AST to self-contained Haskell module
                                                +-- compileRule: writes source, runs `stack exec -- ghc -c`
```

Each generated module is fully self-contained with inlined helper functions (no project imports required), making the generated code portable and independently compilable.

## License

Proprietary — All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root LICENSE file for full terms.
