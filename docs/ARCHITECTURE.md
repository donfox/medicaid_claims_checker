# X12 Fraud Detection DSL - Architecture & Development

## System Architecture

```
┌──────────────────────────────────────────────────────────┐
│              Phoenix Web Frontend (port 4000)             │
│                   Elixir / LiveView                       │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  Rule Editor  ·  Claim Input  ·  Results Display    │ │
│  │  Real-time Validation  ·  GHC Compile Button        │ │
│  └─────────────────────────────────────────────────────┘ │
│                       ↓ HTTP/JSON                         │
└──────────────────────────────────────────────────────────┘
                         │
          POST /api/parse-rule          (validate syntax)
          POST /api/evaluate            (run rule)
          POST /api/compile-rule        (generate + compile Haskell)
          POST /api/evaluate-compiled   (run compiled rule)
          GET  /api/compiled-rules      (list cached rules)
          GET  /api/health
                         │
┌──────────────────────────────────────────────────────────┐
│              Haskell DSL Engine (port 8080)                │
│                                                           │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐ │
│  │    Parser     │──▶│   Rule AST   │──▶│  Evaluator   │ │
│  │   (Parsec)    │   │  (Syntax.hs) │   │  (Simple)    │ │
│  └──────────────┘   └──────┬───────┘   └──────────────┘ │
│                             │                             │
│                    ┌────────▼────────┐                    │
│                    │    Compiler     │                    │
│                    │  AST → Haskell  │                    │
│                    │  source → GHC   │                    │
│                    └─────────────────┘                    │
│                                                           │
│  ┌──────────────┐                    ┌──────────────────┐│
│  │ Rule Engine   │                    │ Compiled Rule    ││
│  │ multi-rule    │                    │ Cache (STM)      ││
│  │ evaluation    │                    └──────────────────┘│
│  └──────────────┘                                        │
└──────────────────────────────────────────────────────────┘
```

## Haskell Modules

### Syntax (`Syntax.hs`)
Defines the AST — the core data types that all other modules operate on.

```haskell
Rule        -- name, description, condition (Predicate), action (Action)
Predicate   -- PTrue, PFalse, Equals, GreaterThan, And, Or, Not, Exists, ForAll, Count, ...
FieldRef    -- Field "amount", SegmentField "CLM" "02", LoopField "2300" "CLM" "02"
Value       -- StringValue, NumberValue, DateValue, ListValue
Action      -- FlagFraud, AssignRiskScore, RequireReview, RejectClaim, CompositeAction
```

### Parser (`Parser.hs`)
Parsec-based recursive descent parser. Handles operator precedence (AND binds tighter than OR), field references in multiple formats, and both compact (`RULE ... ;`) and block (`RULE ... END`) syntax.

### SimpleEvaluator (`SimpleEvaluator.hs`)
Evaluates predicates against generic JSON documents (Aeson `Value`). This is the primary evaluator used by the web UI. Looks up fields via dot-separated paths (e.g., `2300.CLM.02` navigates into nested JSON objects).

### Evaluator (`Evaluator.hs`)
Evaluates predicates against typed `X12Document` structures. Used when working with fully-parsed X12 hierarchies (Interchange > FunctionalGroup > Transaction > Loop > Segment > Element).

### Compiler (`Compiler.hs`)
Code generation and GHC compilation pipeline:

1. **`generateRuleCode`** transforms a Rule AST into a self-contained Haskell module with all helper functions inlined (no project imports needed)
2. **`compileRule`** writes the generated source to a temp file and runs `stack exec -- ghc -c` to verify it compiles
3. **`CompiledRuleCache`** stores compiled rules in a thread-safe STM `TVar` map

```
Rule AST  -->  generateRuleCode  -->  Haskell source (.hs)  -->  GHC verification
                                         │
                                         └── displayed in UI for inspection
```

### RuleEngine (`RuleEngine.hs`)
Orchestrates multi-rule evaluation. Loads rules from DSL text, evaluates each against a document, calculates overall risk level (Low/Medium/High/Critical), and produces an `EvaluationReport`.

### X12Types (`X12Types.hs`)
Type definitions for X12 document hierarchy and evaluation results (`RuleResult`, `Action'`, `RiskLevel`).

### HTTP Server (`Main.hs`)
WAI/Warp server exposing 6 endpoints. Routes requests to parser, evaluator, or compiler. Manages the `CompiledRuleCache` across requests.

## Data Flow

### Rule Evaluation
```
User writes rule  -->  Phoenix validates (POST /api/parse-rule)
User pastes claim JSON
User clicks "Run Rule"  -->  Phoenix POSTs to /api/evaluate
  -->  Haskell: parse rule, evaluateSimpleJson against document
  -->  JSON response: EvaluationReport with results, risk level, details
  -->  Phoenix renders results panel
```

### GHC Compilation
```
User clicks "Compile Rule (GHC)"  -->  Phoenix POSTs to /api/compile-rule
  -->  Haskell: parse rule, generateRuleCode (AST → Haskell source)
  -->  Write source to temp file, run `stack exec -- ghc -c`
  -->  JSON response: success/failure, generated source, timing
  -->  Phoenix renders compilation result + expandable source viewer
```

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Parser library | Parsec | Type-safe, composable, good error messages |
| Architecture | Separate HTTP services | Language separation, independent scaling, easier testing |
| Evaluation strategy | Direct recursive tree walk | Simple, transparent, debuggable |
| JSON evaluator | Generic `Aeson.Value` | Works with any JSON shape, not just typed X12 |
| Code generation output | Self-contained modules | No project imports needed, portable, independently compilable |
| Compiled rule cache | STM `TVar` | Thread-safe, composable, no locks |
| Compilation verification | `stack exec -- ghc -c` | Uses Stack's package resolution correctly |

## Type Safety

Haskell's type system provides:
- **Compile-time guarantees** — type errors caught before runtime
- **Exhaustive pattern matching** — all predicate/action variants handled
- **Algebraic data types** — the AST structure is enforced by the type system
- **Immutability** — no hidden state mutations, safe concurrent evaluation

## Performance

- **Parser**: O(n) in rule text length
- **Evaluator**: O(m * r) where m = rules, r = predicate complexity
- **Field lookup**: O(d) where d = document depth

Optimization opportunities: rule pre-compilation to native code, field indexing, parallel rule evaluation, memoized lookups.

## Development

### Adding a New DSL Feature

1. **Syntax.hs** — add constructor to the relevant type (e.g., new `Predicate` variant)
2. **Parser.hs** — add parsing rule for the new syntax
3. **SimpleEvaluator.hs** — add evaluation case for the new predicate
4. **Compiler.hs** — add code generation case in `generatePredicateCode`
5. **Test** — add test case in `Spec.hs`
6. **Docs** — update SYNTAX_GUIDE.md

Example — adding a `BETWEEN` operator:

```haskell
-- 1. Syntax.hs: add to Predicate
| Between FieldRef Value Value

-- 2. Parser.hs: add parsing
predicateBetween = do
  field <- fieldRef
  _ <- string "BETWEEN"
  val1 <- valueParser; _ <- string "AND"; val2 <- valueParser
  return $ Between field val1 val2

-- 3. SimpleEvaluator.hs: add evaluation
Syntax.Between fieldRef v1 v2 ->
  case (lookupJsonField fieldRef doc, v1, v2) of
    (Just fVal, Syntax.NumberValue n1, Syntax.NumberValue n2) ->
      case textToDouble fVal of { Just n -> n >= n1 && n <= n2; Nothing -> False }
    _ -> False
```

### Debugging

**Haskell REPL:**
```bash
cd haskell_engine && stack ghci
> :load src/X12/DSL/Parser.hs
> parseRule "RULE test \"Test\" WHEN amount > 100 THEN FLAG_FRAUD \"high\";"
```

**Debug output:** Add `import Debug.Trace` then `trace ("debug: " ++ show x) $ ...`

**Phoenix IEx:** `cd phoenix_web && iex -S mix phx.server`

### Build Times

| Scenario | Time |
|---|---|
| First-ever build (all deps) | ~15 minutes |
| Incremental (one file changed) | 20-40 seconds |
| `stack build --fast` | 10-30 seconds |
| Phoenix `mix compile` | 5-15 seconds |
| Server startup | < 1 second |

Use `stack build --fast` during development (disables GHC optimizations). The cabal file already sets `-O0`. The first build compiles 100+ Haskell dependencies — subsequent builds only recompile changed modules.

### Troubleshooting

**Port conflict:** `lsof -i :8080` or `lsof -i :4000`, then `kill <PID>`.

**Build failures:** `cd haskell_engine && stack clean && stack build --fast`

**Parsing issues:** Test with a minimal rule: `RULE test "test" WHEN TRUE THEN FLAG_FRAUD "test";`

## Security Notes

Current implementation assumes trusted input (internal tool). For production:
- API authentication (API keys / JWT)
- Input validation and rate limiting
- HTTPS/TLS
- Audit logging

## Future Directions

- Regex matching (`MATCHES` operator)
- Rule versioning and persistence
- Batch evaluation optimization
- Machine learning integration for anomaly detection
- Formal verification of rule properties
