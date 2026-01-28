# X12 Fraud Detection DSL Engine

Haskell-based engine for parsing and evaluating fraud detection rules written in a domain-specific language for X12 EDI healthcare claims.

## Features

- Domain-Specific Language (DSL) for fraud detection rules
- Parser for business-analyst-friendly syntax
- Predicate evaluator for rule matching
- HTTP API server for rule evaluation
- Support for complex predicates (AND, OR, NOT, EXISTS, FORALL, COUNT)

## Building

```bash
stack build --fast
```

## Running

```bash
stack run
```

The server will start on port 8080.

## API Endpoints

- `GET /api/health` - Health check
- `POST /api/parse-rule` - Parse DSL rule text
- `POST /api/evaluate` - Evaluate rules against X12 documents
