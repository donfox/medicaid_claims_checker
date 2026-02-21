# JSON Claims Integrity

A Haskell-based Domain-Specific Language (DSL) system for fraud/integrity rule evaluation on JSON healthcare claim payloads, with a Phoenix/LiveView web frontend. Some internal module and package names still include X12 for historical reasons.

## Project Structure

```
JSON_claims_integrity/
├── haskell_engine/       # Haskell DSL engine and HTTP server (port 8080)
│   ├── src/
│   │   └── X12/DSL/
│   │       ├── Syntax.hs           # DSL AST types
│   │       ├── Parser.hs           # Parsec-based rule parser
│   │       ├── SimpleEvaluator.hs  # JSON predicate evaluator
│   │       ├── Evaluator.hs        # Typed X12 evaluator
│   │       ├── Compiler.hs         # Code generation + GHC compilation
│   │       ├── RuleEngine.hs       # Multi-rule evaluation engine
│   │       └── X12Types.hs         # X12 document and result types
│   ├── app/
│   │   └── Main.hs                 # HTTP server with all API endpoints
│   └── x12-fraud-dsl.cabal
├── phoenix_web/          # Phoenix/LiveView web frontend (port 4000)
│   └── lib/x12_fraud_web_web/live/rule_live/
│       ├── index.ex                # LiveView module
│       └── index.html.heex         # Template
├── claim_test_data/      # Sample claim JSON files for testing
└── docs/
```

## Quick Start

Start both servers:

```bash
# Terminal 1: Haskell backend
cd haskell_engine
stack run

# Terminal 2: Phoenix frontend
cd phoenix_web
mix phx.server
```

Open http://localhost:4000 in a browser.

## DSL Syntax

The DSL allows business analysts to write fraud detection rules using natural predicate logic:

```
RULE rule_name
DESCRIPTION "Description"
WHEN <predicate>
THEN <action>
END
```

Or compact form:
```
RULE rule_name "Description" WHEN <predicate> THEN <action>;
```

### Predicates

- **Comparisons**: `field = value`, `field > value`, `field < value`, `!=`, `>=`, `<=`
- **Null checks**: `field IS NULL`, `field IS NOT NULL`
- **Logical operators**: `AND`, `OR`, `NOT`
- **Quantifiers**:
  - `EXISTS loop.segment WHERE predicate`
  - `FORALL loop.segment WHERE predicate`
  - `COUNT(loop) > n`
- **String operations**: `field CONTAINS value`

### Field References

Fields use dot-separated paths matching the JSON document structure:

- Simple: `amount` -- direct key lookup
- Nested: `claim.amount` -- dot-separated path
- X12-style: `2300.CLM.02` -- loop.segment.element position

### Actions

- `FLAG_FRAUD "reason"` -- Flag claim as potentially fraudulent
- `REJECT "reason"` -- Reject the claim
- `REQUIRE_REVIEW "note"` -- Require manual review
- `RISK_SCORE n` -- Assign risk score (0-100)
- `[action1, action2, ...]` -- Multiple actions

### Example Rules

```
RULE high_claim_amount
DESCRIPTION "Flag claims over $50,000"
WHEN 2300.CLM.02 > 50000
THEN FLAG_FRAUD "Claim amount exceeds threshold"
END

RULE duplicate_claims "Detect potential duplicates"
WHEN COUNT(2300) > 5
THEN REQUIRE_REVIEW "Multiple claims same day";

RULE missing_diagnosis "Diagnosis required"
WHEN 2300.HI.01 IS NULL
THEN REJECT "Missing diagnosis code";
```

## GHC Compilation Pipeline

Rules can be compiled into standalone Haskell modules via GHC:

```
DSL Text  -->  Parser  -->  Rule AST  -->  Code Generator  -->  Haskell Module  -->  GHC
```

The "Compile Rule (GHC)" button in the UI triggers this pipeline:

1. The Rule AST is transformed into a self-contained Haskell module with all helper functions inlined
2. The generated source is written to a temp file and compiled with `stack exec -- ghc -c`
3. GHC verifies the code is valid, optimisable Haskell
4. The generated source is displayed in the UI for inspection

This demonstrates that the DSL's type system maps cleanly to Haskell's type system, and that rules can be compiled to native code for production deployment.

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/health` | GET | Health check |
| `/api/parse-rule` | POST | Parse DSL rule text, return AST |
| `/api/evaluate` | POST | Evaluate rules against a JSON document |
| `/api/compile-rule` | POST | Generate Haskell source and compile with GHC |
| `/api/evaluate-compiled` | POST | Evaluate using a previously compiled rule |
| `/api/compiled-rules` | GET | List cached compiled rules |

## Prerequisites

- GHC >= 9.2 (via Stack)
- Elixir >= 1.14 / Phoenix >= 1.7

## License

BSD-3-Clause
