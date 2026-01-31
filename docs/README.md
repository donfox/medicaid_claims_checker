# X12 Fraud Detection DSL

A Haskell-based Domain-Specific Language (DSL) for writing fraud detection rules for X12 EDI healthcare claims (837P), with a Phoenix/LiveView web frontend.

## Project Structure

```
x12_fraud_dsl/
├── haskell_engine/       # Haskell DSL engine and HTTP server
│   ├── src/             # Source code
│   │   └── X12/DSL/
│   │       ├── Syntax.hs      # DSL syntax definition
│   │       ├── Parser.hs      # Rule parser
│   │       ├── Evaluator.hs   # Predicate evaluator
│   │       ├── X12Types.hs    # X12 document types
│   │       └── RuleEngine.hs  # Rule evaluation engine
│   ├── app/             # HTTP server application
│   │   └── Main.hs
│   ├── test/            # Tests
│   └── x12-fraud-dsl.cabal
├── phoenix_web/         # Phoenix web frontend (to be created)
└── examples/            # Example fraud detection rules
    ├── sample_rules.dsl
    └── simple_rules.dsl
```

## DSL Syntax

The DSL allows business analysts to write fraud detection rules using natural predicate logic:

```
RULE rule_name "Description"
WHEN <predicate>
THEN <action>;
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

- Simple: `field_name`
- Segment-qualified: `CLM.claim_amount`
- Loop-qualified: `2300.CLM.claim_amount`

### Actions

- `FLAG_FRAUD "reason"` - Flag claim as potentially fraudulent
- `REJECT "reason"` - Reject the claim
- `REQUIRE_REVIEW "note"` - Require manual review
- `RISK_SCORE n` - Assign risk score (0-100)
- `[action1, action2, ...]` - Multiple actions

### Example Rules

```
-- High claim amount
RULE high_claim_amount "Flag claims over $50,000"
WHEN 2300.CLM.claim_amount > 50000.0
THEN FLAG_FRAUD "Claim amount exceeds threshold";

-- Duplicate detection
RULE duplicate_claims "Detect potential duplicates"
WHEN COUNT(2300) > 5
THEN REQUIRE_REVIEW "Multiple claims same day";

-- Missing required data
RULE missing_diagnosis "Diagnosis required"
WHEN 2300.HI.diagnosis_code IS NULL
THEN REJECT "Missing diagnosis code";

-- Complex pattern
RULE unbundling "Check for unbundled procedures"
WHEN EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99213"
     AND EXISTS 2400.SV1 WHERE 2400.SV1.procedure_code = "99214"
THEN FLAG_FRAUD "Possible unbundling";
```

## Building and Running

### Prerequisites

- GHC >= 9.2
- Stack or Cabal
- Elixir/Phoenix (for web frontend)

### Build Haskell Engine

```bash
cd haskell_engine

# Using Stack
stack build
stack run

# Using Cabal
cabal build
cabal run x12-fraud-dsl-server
```

The HTTP server will start on port 8080.

### API Endpoints

**POST /api/evaluate**
```json
{
  "rules": "RULE test \"Test\" WHEN ... THEN ...;",
  "document": { ... }
}
```

**POST /api/parse-rule**
```json
{
  "ruleText": "RULE test \"Test\" WHEN ... THEN ...;"
}
```

**GET /api/health**

## Integration with Phoenix

The Phoenix web application will provide:
- Web-based rule editor with syntax highlighting
- Real-time rule validation
- Visual claim analysis dashboard
- Historical evaluation reports
- Rule library management

## X12 837P Structure Reference

Common loops and segments:
- `2300` - Claim Information (CLM segment)
- `2400` - Service Line (SV1 segment)
- `2010` - Provider/Patient Name (NM1 segment)
- `DTP` - Date/Time reference
- `HI` - Health Care Diagnosis Code

## License

BSD-3-Clause

## Author

Healthcare Analytics Team
