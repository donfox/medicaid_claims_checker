# X12 Fraud Detection DSL - Architecture & Implementation

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Phoenix Web Frontend                       │
│                    (Elixir/LiveView)                         │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         Rule Editor Interface                        │   │
│  │  - Syntax Highlighting                              │   │
│  │  - Real-time Validation                             │   │
│  │  - Visual Rule Composition                          │   │
│  │  - Evaluation Results Display                       │   │
│  └──────────────────────────────────────────────────────┘   │
│                          ↓ HTTP/JSON                         │
└─────────────────────────────────────────────────────────────┘
                           │
                    POST /api/evaluate
                   POST /api/parse-rule
                    GET /api/health
                           │
┌─────────────────────────────────────────────────────────────┐
│                  Haskell DSL Engine                          │
│                   (HTTP Server)                              │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            Rule Parser (Parsec)                      │   │
│  │  - Tokenization                                      │   │
│  │  - Syntax Analysis                                  │   │
│  │  - AST Generation                                   │   │
│  └──────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Predicate Evaluator                        │   │
│  │  - Condition Evaluation                              │   │
│  │  - Field Resolution                                 │   │
│  │  - Logical Operators (AND, OR, NOT)                │   │
│  │  - Quantifiers (EXISTS, FORALL, COUNT)             │   │
│  └──────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Rule Engine                                │   │
│  │  - Load Rules                                        │   │
│  │  - Evaluate Against X12 Documents                   │   │
│  │  - Generate Risk Assessment                         │   │
│  │  - Compile Evaluation Reports                       │   │
│  └──────────────────────────────────────────────────────┘   │
│                          ↓                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         X12 Document Parser                          │   │
│  │  - Loop/Segment Navigation                           │   │
│  │  - Field Resolution                                 │   │
│  │  - Hierarchical Structure Traversal                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                           ↑
                      JSON Response
                   EvaluationReport

┌─────────────────────────────────────────────────────────────┐
│              X12 837P Claims Data                            │
│         (Parsed into Document Structure)                     │
└─────────────────────────────────────────────────────────────┘
```

## Component Breakdown

### 1. Haskell DSL Engine (`haskell_engine/`)

#### Syntax Layer (`Syntax.hs`)
- Defines DSL abstract syntax tree (AST)
- Data types for rules, predicates, fields, values, and actions
- JSON serialization via Aeson

**Key Types:**
```haskell
Rule              - Complete rule definition
Predicate         - Logical expression
FieldRef          - Reference to X12 field
Value             - Literal value
Action            - Consequence of rule match
SegmentPath       - X12 loop/segment path
```

#### Parser Layer (`Parser.hs`)
- Uses Parsec library for parsing
- Lexical analysis and tokenization
- Recursive descent parser for predicate expressions
- Operator precedence handling (AND > OR, etc.)

**Parsing Strategy:**
1. Tokenize rule text
2. Parse rule structure: RULE name "desc" WHEN pred THEN action;
3. Parse predicates with operator precedence
4. Parse field references (simple, qualified, composite)
5. Parse actions
6. Return AST or parse error

#### Evaluator Layer (`Evaluator.hs`)
- Evaluates predicates against X12 documents
- Field resolution and lookup
- Logical operator evaluation (AND, OR, NOT)
- Quantifier handling (EXISTS, FORALL, COUNT)
- Comparison operations

**Evaluation Strategy:**
```
evaluatePredicate :: X12Document -> Predicate -> Bool
- Recursively evaluate predicate tree
- Look up field values in document
- Apply comparison/logical operations
- Return boolean result
```

#### X12 Types (`X12Types.hs`)
- Represents parsed X12 837P document structure
- Interchange → FunctionalGroup → Transaction → Loop → Segment → Element
- Result types for evaluation outcomes
- Risk assessment data structures

#### Rule Engine (`RuleEngine.hs`)
- Manages collection of loaded rules
- Orchestrates rule evaluation
- Generates comprehensive evaluation reports
- Calculates overall risk level
- Provides summary and details

**Risk Levels:**
- LowRisk: No issues detected
- MediumRisk: Minor issues or recommendations
- HighRisk: Multiple significant issues
- CriticalRisk: Rejection required or fraud flagged

#### HTTP Server (`Main.hs`)
- WAI/Warp HTTP server on port 8080
- Three main endpoints:
  - `POST /api/parse-rule` - Parse and validate rule
  - `POST /api/evaluate` - Evaluate rules against document
  - `GET /api/health` - Health check
- JSON request/response handling
- Error handling and reporting

### 2. Phoenix Web Frontend (`phoenix_web/`)

#### LiveView Components
**RuleLive.Index** (`rule_live/index.ex`)
- Interactive rule editor with real-time validation
- Rule text input with line numbers
- Parse error display
- Evaluation results rendering
- Sample X12 document inclusion

**Components** (`rule_components.ex`)
- Risk badge component with color coding
- Reusable UI elements
- Styling with Tailwind CSS

#### Templates
**index.html.heex**
- Rule editor form
- Results panel with risk assessment
- DSL syntax reference
- Side-by-side layout for editing and evaluation

#### Router
**router.ex**
- `GET /` - Home page
- `GET /rules` - Rule editor LiveView
- REST API routes (to be expanded)

### 3. Examples (`examples/`)

**sample_rules.dsl** - Comprehensive fraud detection rules
- High claim amount detection
- Duplicate claim detection
- Service date validation
- Unbundling detection
- Provider eligibility checks
- Age-inappropriate service detection

**simple_rules.dsl** - Basic examples for learning

## Data Flow

### Rule Parsing Flow
```
User Input (Rule Text)
    ↓
Phoenix LiveView validates
    ↓
HTTP POST to /api/parse-rule
    ↓
Haskell Parser.parseRule
    ↓
Parsec lexer/parser
    ↓
Return AST or ParseError
    ↓
JSON response to Phoenix
    ↓
Display result to user
```

### Rule Evaluation Flow
```
X12 Document + Rules
    ↓
HTTP POST to /api/evaluate
    ↓
Haskell RuleEngine.loadRules
    ↓
Evaluator.evaluatePredicate (per rule)
    ↓
Field lookup in X12 structure
    ↓
Logical evaluation
    ↓
Action execution
    ↓
Generate RuleResult
    ↓
Calculate overall risk
    ↓
Compile EvaluationReport
    ↓
JSON response with detailed results
    ↓
Display in Phoenix UI
```

## Key Design Decisions

### 1. Parser Implementation
- **Choice**: Parsec (Haskell parsing library)
- **Rationale**: Type-safe, composable, minimal overhead, good error messages
- **Alternative Considered**: Hand-written recursive descent (more control, but verbose)

### 2. HTTP Separation
- **Choice**: Separate Haskell HTTP server, called via HTTP from Phoenix
- **Rationale**: 
  - Language separation of concerns
  - Independent scaling
  - Easier testing
  - Can be distributed
- **Alternative**: Direct library integration (would require Elixir bindings)

### 3. Predicate Evaluation Strategy
- **Choice**: Direct recursive evaluation tree walk
- **Rationale**: Simple, transparent, debuggable
- **Could optimize**: Short-circuit evaluation, memoization, parallel evaluation

### 4. X12 Document Structure
- **Choice**: Hierarchical JSON-like representation
- **Rationale**: Natural for Haskell types, easy JSON serialization, flexible
- **Could improve**: Type-indexed fields for compile-time safety

## Type Safety Features

### Haskell Benefits
1. **Compile-time Guarantees**
   - Type errors caught before runtime
   - Exhaustive pattern matching
   - No null pointer exceptions

2. **Type System**
   - Phantom types for field safety
   - Algebraic data types for predicate structure
   - Function signatures document intent

3. **Immutability**
   - No hidden state mutations
   - Easier to reason about evaluation
   - Safe concurrent evaluation

## Performance Characteristics

### Current Implementation
- **Parser**: O(n) in rule text length
- **Evaluator**: O(m*r) where m = rules, r = predicate complexity
- **Field Lookup**: O(d) where d = document depth

### Optimization Opportunities
1. **Rule Compilation**: Pre-compile rules to bytecode
2. **Indexing**: Pre-index X12 document fields
3. **Parallel Evaluation**: Evaluate independent rules concurrently
4. **Caching**: Memoize field lookups
5. **Specialized Rules**: JIT compile frequently used patterns

## Testing Strategy

### Unit Tests
- Parser tests: Rule syntax validation
- Evaluator tests: Predicate evaluation
- Integration tests: End-to-end rule evaluation

### Example Test Cases
```haskell
-- Parser tests
parseRule "RULE test \"Test\" WHEN ... THEN ...;" -- Should succeed
parseRule "RULE test" -- Should fail (incomplete)

-- Evaluator tests  
evaluatePredicate doc (Equals field val) -- Specific value match
evaluatePredicate doc (And p1 p2) -- Logical conjunction
evaluatePredicate doc (Exists path pred) -- Quantified expression
```

## Future Enhancements

### Near Term
1. Regex pattern matching in MATCHES operator
2. Rule versioning and history
3. Rule library/marketplace
4. More sophisticated risk scoring algorithm
5. Batch evaluation optimization

### Medium Term
1. Machine learning integration for pattern detection
2. Rule conflicts and precedence handling
3. Performance metrics and profiling
4. Caching layer for repeated evaluations
5. Horizontal scaling with distributed evaluation

### Long Term
1. Formal verification of rule properties
2. Fuzzing and property-based testing
3. Custom function definitions
4. Database integration for rule persistence
5. Audit trails and compliance reporting

## Deployment Considerations

### Local Development
```bash
# Terminal 1
cd haskell_engine && stack build && stack run

# Terminal 2
cd phoenix_web && mix phx.server
```

### Docker Containerization
Can containerize Haskell engine and Phoenix separately for:
- Production deployment
- Horizontal scaling
- Container orchestration (Kubernetes)

### Monitoring
- Add Prometheus metrics
- Log important decisions
- Track rule evaluation performance
- Monitor HTTP endpoint availability

## Security Considerations

### Current Implementation
- No authentication on HTTP endpoints
- Assumes trusted input (rules are written by business analysts)
- No rate limiting

### Production Hardening
1. Add API authentication (API keys, JWT)
2. Input validation and sanitization
3. Rate limiting
4. CORS configuration
5. HTTPS/TLS
6. SQL injection prevention (if database added)
7. Audit logging for compliance
