# JSON_claims_integrity - Project Status

## Status: ✅ VERIFIED

**Purpose**: Haskell-based Domain-Specific Language (DSL) engine for writing business-analyst-friendly fraud detection rules for JSON claim payloads, with Phoenix web frontend

## Architecture
```
Phoenix LiveView UI (Elixir, Port 4000)
         ↓ HTTP
Haskell DSL Engine (Wai/Warp, Port 8080)
```

## Components

### Haskell DSL Engine
- `X12/DSL/Syntax.hs` - DSL syntax definition
- `X12/DSL/Parser.hs` - Rule text parser (Parsec)
- `X12/DSL/Evaluator.hs` - Predicate evaluation
- `X12/DSL/RuleEngine.hs` - Rule matching engine
- HTTP API: parse rules, evaluate against JSON claim payloads

### Phoenix Web UI (Elixir LiveView)
- Rule editor with syntax highlighting
- Real-time rule validation
- Visual claim analysis dashboard
- Rule library management

## DSL Example
```
RULE high_claim_amount "Flag claims over $50,000"
WHEN 2300.CLM.claim_amount > 50000.0
THEN FLAG_FRAUD "Claim amount exceeds threshold";
```

## Run Command
```bash
./start.sh [--install]
```

## Proprietary Use Notice

This project is proprietary. All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root LICENSE file for full terms.
