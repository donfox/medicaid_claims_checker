# Haskell Engine — Architecture and Reference

---

## Functional Programming Design

The rule evaluation engine is written in Haskell, a purely functional language.

- Rules are parsed into an AST and evaluated via pattern matching and recursive descent.
- [src/X12/DSL/Syntax.hs](../../haskell_engine/src/X12/DSL/Syntax.hs) defines the DSL grammar as algebraic data types (ADTs) — a hallmark FP design.
- [src/X12/DSL/RuleEngine.hs](../../haskell_engine/src/X12/DSL/RuleEngine.hs) and [src/X12/DSL/SimpleEvaluator.hs](../../haskell_engine/src/X12/DSL/SimpleEvaluator.hs) compose rule evaluation functionally, with no mutable state.
- [src/X12/DSL/PolicyCombiner.hs](../../haskell_engine/src/X12/DSL/PolicyCombiner.hs) combines rule results using combinators — a classic FP pattern.

The Elixir/Phoenix frontend is also functional: Phoenix LiveView uses immutable state diffs and message-passing, and the claims context uses pipelines (`|>`) and pure transformations. This split is deliberate — the Haskell engine handles *rule logic* (pure, stateless, easily testable) while Elixir handles *web and state management*. Side effects (DB, HTTP) are pushed to the edges; the rule evaluation core remains pure.

---

## Big Picture

```
  CLIENT (Phoenix / curl / test script)
          │
          │  POST /api/batch-evaluate
          │  Body: { "rulesText": "...", "claims": [...] }
          ▼
  ┌─────────────────────────────────────────────────────────┐
  │                  Main.hs  (Warp HTTP server)            │
  │                                                         │
  │  1. Decode JSON body                                    │
  │  2. Split into  rulesText  and  claims[]                │
  └───────────┬─────────────────────────┬───────────────────┘
              │                         │
              ▼                         ▼
      ┌───────────────┐         ┌───────────────┐
      │  RuleEngine   │         │  [Aeson.Value]│
      │  loadRules    │         │  (JSON claims)│
      └───────┬───────┘         └───────┬───────┘
              │                         │
              │  parseRules             │
              ▼                         │
      ┌───────────────┐                 │
      │   [Rule]      │◄────────────────┘
      │  (AST list)   │   evaluateSimpleJson
      └───────┬───────┘   maps each claim over
              │           every Rule in the list
              ▼
      ┌───────────────────────────────┐
      │       SimpleEvaluator         │
      │                               │
      │  for each (claim, rule):      │
      │    1. resolve LET bindings    │
      │    2. walk Predicate AST      │
      │    3. lookup JSON fields      │
      │    4. compare values          │
      │    5. return RuleResult       │
      └───────────────────────────────┘
              │
              ▼
      ┌───────────────────────────────┐
      │       EvaluationReport        │
      │                               │
      │  • results   : [RuleResult]   │
      │  • riskLevel : Low/Med/High/  │
      │                Critical       │
      │  • summary   : Text           │
      └───────────────────────────────┘
              │
              ▼
      JSON response back to client
```

See also: [dsl_evaluation_flow.svg](dsl_evaluation_flow.svg)

---

## Evaluation Pipeline

### Step 1 — HTTP Request and Routing

File: [app/Main.hs](../../haskell_engine/app/Main.hs)

The Warp web server receives the POST. `pathInfo` splits the URL into a list; Haskell's `case` expression matches it to the right handler — no framework, just pattern matching.

```haskell
case pathInfo request of
  ["api", "batch-evaluate"] -> handleBatchEvaluate request respond
  ["api", "evaluate"]       -> handleEvaluate       request respond
  ["api", "compile-rules"]  -> handleCompileRules cache request respond
  ["api", "parse-rule"]     -> handleParseRule      request respond
  ["api", "health"]         -> handleHealth         respond
  _                         -> respond $ responseLBS status400 [] "Not found"
```

The handler decodes the raw HTTP body into a `BatchEvaluationRequest`:

```haskell
data BatchEvaluationRequest = BatchEvaluationRequest
  { batchRulesText :: Text          -- the DSL rule program
  , batchClaims    :: [Aeson.Value] -- list of JSON claim objects
  }
```

---

### Step 2 — Parsing DSL Text into an AST

File: [src/X12/DSL/RuleEngine.hs](../../haskell_engine/src/X12/DSL/RuleEngine.hs)

```haskell
loadRules :: Text -> Either String RuleEngine
loadRules rulesText = case parseRules rulesText of
  Left  err   -> Left  ("Parse error: " ++ show err)
  Right rules -> Right (RuleEngine rules)
```

`parseRules` reads raw DSL text and produces `[Rule]` — in-memory Haskell data structures.
`Either` is Haskell's "success or failure" type: `Left err` on failure, `Right rules` on success.
After this step the text is gone; the engine works entirely with the AST.

---

### Step 3 — Rule (AST) Structure

File: [src/X12/DSL/Syntax.hs](../../haskell_engine/src/X12/DSL/Syntax.hs)

A `Rule` is a Haskell record (like a struct) with five fields:

```
Rule
 ├── ruleName        : Text       e.g. "high_amount"
 ├── ruleDescription : Text       e.g. "Flag claims over $10,000"
 ├── ruleBindings    : [Binding]  optional  LET x = some.field  aliases
 ├── ruleCondition   : Predicate  ← the boolean expression tree
 └── ruleAction      : Action     what to do when condition is true
```

`WHEN amount > 10000 THEN FLAG_FRAUD "large"` becomes:

```
ruleCondition = GreaterThan
                  (Field "amount")       ← field reference
                  (NumberValue 10000.0)  ← literal number

ruleAction    = FlagFraud "large"
```

`Predicate` is a **tree** — complex rules nest predicates inside each other:

```
WHEN amount > 10000 AND status = "pending"

         And
        /    \
 GreaterThan  Equals
 (amount,     (status,
  10000)       "pending")
```

---

### Step 4 — Evaluating Each Claim

File: [src/X12/DSL/RuleEngine.hs](../../haskell_engine/src/X12/DSL/RuleEngine.hs)

```haskell
evaluateSimpleJson :: RuleEngine -> Aeson.Value -> EvaluationReport
evaluateSimpleJson engine claimDoc =
  let results = map (evaluateRuleSimple claimDoc) (engineRules engine)
```

`map f list` applies `f` to every element. Every rule is always evaluated — there is no short-circuit on first match. All results are collected and `determineRiskLevel` picks the worst outcome.

```
rules   = [ rule1,   rule2,   rule3,   ... ]
                │        │        │
                ▼        ▼        ▼
                evaluateRuleSimple claim
                │        │        │
                ▼        ▼        ▼
results = [ result1, result2, result3, ... ]
```

---

### Step 5 — Walking the Predicate Tree

File: [src/X12/DSL/SimpleEvaluator.hs](../../haskell_engine/src/X12/DSL/SimpleEvaluator.hs)

The evaluator uses an `EvalEnv` (evaluation environment) that carries three pieces of context:

```
EvalEnv
 ├── envLetBindings : Map Text Text         -- LET aliases (e.g., LET amt = claim.amount)
 ├── envScopeVars   : Map Text Aeson.Value  -- named quantifier variables (e.g., x bound by EXISTS x IN ...)
 └── envDoc         : Aeson.Value           -- current JSON document context
```

Field resolution checks scope variables first (for named quantifier bindings), then LET bindings, then the document. This enables nested quantifiers to access both inner and outer bound elements — the key mechanism for first-order predicate calculus equivalence.

The core `evaluateWithEnv` function is **recursive**, pattern-matching on each predicate node:

```
Predicate node            What the evaluator does
───────────────────────   ─────────────────────────────────────────────
GreaterThan field val     look up field in JSON → parse as number → compare
Equals      field val     look up field in JSON → compare as string
And p1 p2                 evaluate p1 AND evaluate p2  (recurse both branches)
Or  p1 p2                 evaluate p1 OR  evaluate p2  (recurse both branches)
Not p                     NOT (evaluate p)              (recurse one branch)
Between field lo hi       look up field → check lo <= field <= hi (inclusive)
HasDiagnosis "code"       search diagnosis_codes[*].code in claim
HasProcedure "code"       search procedure_codes/service_lines[*].procedure_code
Exists (Just x) path p    bind each element to x in envScopeVars → evaluate p
Exists Nothing  path p    shift envDoc to each element → evaluate p (legacy)
ForAll (Just x) path p    bind each element to x → check ALL satisfy p
ForAll Nothing  path p    shift envDoc to each element → check ALL
IsNull field              field missing or null → true
HelperCall "is_weekend"   extract date field → check day-of-week
```

---

### Step 6 — JSON Field Lookup

File: [src/X12/DSL/SimpleEvaluator.hs](../../haskell_engine/src/X12/DSL/SimpleEvaluator.hs)

Field references are resolved by navigating the JSON object tree using dot-separated path segments. Array elements are accessed by numeric index.

```
FieldRef in rule DSL      JSON claim structure        Result
────────────────────────  ──────────────────────────  ──────────
Field "amount"            { "amount": 15000 }         "15000"
Field "claim.amount"      { "claim": { "amount": 9 }} "9"
SegmentField "CLM" "01"   { "CLM": { "01": "X" } }   "X"
Field "items.0.price"     { "items": [{"price": 5}] } "5"
```

All JSON leaf values are coerced to `Text` (plain string) for comparison:

```
JSON type    Becomes
──────────   ───────────────────────────
"pending"  → "pending"
15000      → "15000.0"
true       → "true"
null       → Nothing  (field treated as missing)
```

---

### Step 7 — Result and Risk Aggregation

File: [src/X12/DSL/RuleEngine.hs](../../haskell_engine/src/X12/DSL/RuleEngine.hs)

Each rule produces a `RuleResult`:

```
RuleResult
 ├── resultRuleName : Text          "high_amount"
 ├── resultMatched  : Bool          True / False
 ├── resultAction   : Maybe Action  Just (FlagFraud' "large")  or  Nothing
 └── resultDetails  : Text          "Rule matched: ..."
```

`determineRiskLevel` scans all results and picks the worst:

```
Any FlagFraud or RejectClaim action?     → CriticalRisk
3 or more rules scored >= 70?            → HighRisk
1 or 2 rules scored >= 70?              → MediumRisk
Nothing significant triggered?          → LowRisk
ApproveClaim only?                       → LowRisk (does not elevate risk)
```

The final `EvaluationReport` is serialised to JSON and returned in the HTTP response.

---

## Rule Storage

There are two distinct places rules can live, depending on which API endpoint is used.

### Storage 1 — `RuleEngine` list (per-request, temporary)

File: [src/X12/DSL/RuleEngine.hs](../../haskell_engine/src/X12/DSL/RuleEngine.hs)

```haskell
data RuleEngine = RuleEngine
  { engineRules :: [Rule]   -- a plain Haskell list of Rule ASTs
  }
```

Used by `/api/batch-evaluate`. The DSL text is parsed **fresh on every request** and stored here for the lifetime of that one request. When the HTTP response is sent the list is discarded — nothing persists.

### Storage 2 — `CompiledRuleCache` (server-lifetime, persistent)

File: [src/X12/DSL/RuleCache.hs](../../haskell_engine/src/X12/DSL/RuleCache.hs)

```haskell
data CompiledRuleCache = CompiledRuleCache
  { cacheRules :: TVar (Map Text CompiledRule)
  }
```

This map lives for the **entire server lifetime**, allocated once in `main` and shared across all requests:

```haskell
main :: IO ()
main = do
  cache <- newCompiledRuleCache   -- created once
  run 8080 (app cache)            -- shared across all requests
```

Rules enter the cache via `/api/compile-rules`. Each entry is a `CompiledRule`:

```haskell
data CompiledRule = CompiledRule
  { compiledRuleName :: Text
  , compiledFunction :: Aeson.Value -> RuleResult  -- claim in, result out
  , compiledAt       :: UTCTime
  }
```

`compiledFunction` is a **pre-built evaluation function** — the AST is already bound inside it, so there is no re-parsing on each claim. `TVar` is Haskell's *transactional variable*; reads and writes are wrapped in `atomically`, making the cache thread-safe.

In the cache path, `compileRules` uses `mapM` (the IO-capable version of `map`):

```haskell
compileRules :: [Rule] -> IO [CompilationResult]
compileRules = mapM compileRule
```

`mapM` is needed because `compileRule` has a side effect (recording a timestamp via `getCurrentTime`), whereas plain `map` only works with pure functions.

### Comparison

| | `RuleEngine` list | `CompiledRuleCache` |
|---|---|---|
| **File** | RuleEngine.hs | RuleCache.hs |
| **Lives for** | One request | Entire server lifetime |
| **Populated by** | `/api/batch-evaluate` (parse on every call) | `/api/compile-rules` (explicit pre-load) |
| **Storage type** | `[Rule]` — plain list | `TVar (Map Text CompiledRule)` — thread-safe map |
| **Apply to claim** | `map (evaluateRuleSimple doc) rules` | call `compiledFunction claim` per entry |
| **Thread safe?** | N/A (request-local) | Yes — `atomically` via STM |
| **Re-parses DSL?** | Every request | No — parsed once, function pre-built |

---

## Claim Structure

What a decoded medical claim looks like. Examples from [test/fixtures/claims/](../../phoenix_web/test/fixtures/claims/).

### Example 1 — Normal / Approved Claim

Source: [claim_normal_approved.json](../../phoenix_web/test/fixtures/claims/claim_normal_approved.json)

A low-value office visit ($150) with a valid authorisation and a known provider. Expected result: `APPROVED`.

```json
{
  "claim_id": "CLM-NORMAL-001",
  "submission_type": "healthcare_claim_997",
  "provider": {
    "name": "Kansas City Medical Center",
    "npi": "1234567901",
    "type": "Clinic",
    "state": "MO",
    "risk_score": 25,
    "tenure_days": 800,
    "specialty": "Family Medicine"
  },
  "patient": {
    "name": { "first": "Elizabeth", "last": "Wilson" },
    "date_of_birth": "1982-10-12",
    "gender": "Female",
    "patient_id": "PAT-008"
  },
  "claim_details": {
    "admission_date": "2026-01-27",
    "discharge_date": "2026-01-27",
    "service_type": "Office Visit",
    "place_of_service": "11"
  },
  "diagnosis_codes": [
    { "code": "Z00.00", "description": "Encounter for general adult medical examination", "qualifier": "Principal" }
  ],
  "service_lines": [
    { "service_line_number": 1, "procedure_code": "99213", "description": "Office visit - established patient, low complexity", "units": 1, "unit_rate": 150.00, "line_amount": 150.00, "date_of_service": "2026-01-27" }
  ],
  "financial": { "claim_amount": 150.00, "patient_copay": 25.00 },
  "authorization": { "authorization_number": "AUTH-444444", "authorization_status": "Active", "authorized_amount": 200.00 },
  "claim_metadata": { "submission_date": "2026-01-29", "claim_processing_status": "Pending", "expected_result": "APPROVED" }
}
```

### Example 2 — High-Amount Fraud Trigger

Source: [claim_high_amount_trigger.json](../../phoenix_web/test/fixtures/claims/claim_high_amount_trigger.json)

A $75,000 hospital inpatient claim. Expected result: `FLAG_FRAUD`.

```json
{
  "claim_id": "CLM-HIGH-AMOUNT-001",
  "submission_type": "healthcare_claim_997",
  "claim": { "amount": 75000, "units": 10, "frequency": "12", "drg_code": "640" },
  "provider": {
    "name": "Premium Medical Center",
    "npi": "1234567890",
    "type": "Hospital",
    "state": "CA",
    "risk_score": 25,
    "tenure_days": 500,
    "specialty": "Acute Care Hospital"
  },
  "patient": {
    "name": { "first": "John", "last": "Smith" },
    "date_of_birth": "1981-03-15",
    "gender": "Male",
    "patient_id": "PAT-001"
  },
  "claim_details": {
    "admission_date": "2026-01-10",
    "discharge_date": "2026-01-20",
    "admission_type": "Emergency",
    "service_type": "Hospital Inpatient",
    "drg_code": "640",
    "days_stay": 10
  },
  "diagnosis_codes": [
    { "code": "E11.9", "description": "Type 2 diabetes mellitus", "qualifier": "Principal" },
    { "code": "I10",   "description": "Essential hypertension",   "qualifier": "Secondary" }
  ],
  "service_lines": [
    { "service_line_number": 1, "procedure_code": "99213", "units": 5, "unit_rate": 150.00, "line_amount": 750.00, "date_of_service": "2026-01-15" },
    { "service_line_number": 2, "procedure_code": "80053", "units": 1, "unit_rate": 85.00,  "line_amount": 85.00,  "date_of_service": "2026-01-10" }
  ],
  "financial": { "claim_amount": 75000.00, "patient_copay": 0.00 },
  "authorization": { "authorization_number": "AUTH-123456", "authorization_status": "Active", "authorized_amount": 80000.00 },
  "claim_metadata": { "submission_date": "2026-01-29", "claim_processing_status": "Pending", "expected_result": "FLAG_FRAUD" }
}
```

### Aeson Internal Representation

**Aeson** is the standard Haskell library for JSON parsing and encoding — the name is a pun on "Jason" (the Greek mythological hero) and "JSON". It defines a `Value` type that mirrors the JSON data model exactly, so every JSON document can be represented as a Haskell value without any information loss.

When the HTTP body is decoded, Aeson produces an `Aeson.Value` tree. Every JSON type maps to an Aeson constructor:

```
JSON type          Aeson constructor        Example
─────────────────  ───────────────────────  ────────────────────────────
{ "key": ... }     Aeson.Object (KeyMap)    the whole claim document
[ ... ]            Aeson.Array  (Vector)    diagnosis_codes, service_lines
"some text"        Aeson.String Text        "CLM-HIGH-AMOUNT-001"
75000              Aeson.Number Scientific  75000
true / false       Aeson.Bool   Bool        true
null               Aeson.Null               null
```

The in-memory representation of `claim_high_amount_trigger.json`:

```
Aeson.Object
  "claim_id"      → Aeson.String "CLM-HIGH-AMOUNT-001"
  "claim"         → Aeson.Object
                      "amount" → Aeson.Number 75000
                      "units"  → Aeson.Number 10
  "provider"      → Aeson.Object
                      "npi"   → Aeson.String "1234567890"
                      "state" → Aeson.String "CA"
  "service_lines" → Aeson.Array
                      [0] → Aeson.Object
                              "procedure_code" → Aeson.String "99213"
                              "units"          → Aeson.Number 5
                      [1] → Aeson.Object
                              "procedure_code" → Aeson.String "80053"
                              "units"          → Aeson.Number 1
  "financial"     → Aeson.Object
                      "claim_amount" → Aeson.Number 75000.0
  "authorization" → Aeson.Object
                      "authorization_status" → Aeson.String "Active"
```

### Field Extraction by DSL Reference

`lookupJsonField` splits a dot-path into segments and walks the tree:

| DSL field reference | Path walked | Value returned |
|---|---|---|
| `Field "claim_id"` | top level | `"CLM-HIGH-AMOUNT-001"` |
| `Field "claim.amount"` | `claim` → `amount` | `"75000.0"` |
| `Field "provider.state"` | `provider` → `state` | `"CA"` |
| `Field "authorization.authorization_status"` | `authorization` → `authorization_status` | `"Active"` |
| `Field "service_lines.0.procedure_code"` | array index 0 → field | `"99213"` |
| `Field "service_lines.1.units"` | array index 1 → field | `"1.0"` |

---

## End-to-End Example

### Input (POST body)

```json
{
  "rulesText": "RULE high_amount \"High value claim\" WHEN amount > 10000 THEN FLAG_FRAUD \"Unusually large amount\";",
  "claims": [
    { "amount": 15000, "provider": "NPI123", "status": "pending" }
  ]
}
```

### Pipeline trace

```
rulesText  ──► parseRules ──► Rule { ruleName      = "high_amount"
                                   , ruleCondition = GreaterThan (Field "amount") (NumberValue 10000)
                                   , ruleAction    = FlagFraud "Unusually large amount"
                                   }

claim JSON ──► evaluateRuleSimple
                  │
                  ├─ lookupJsonField (Field "amount") claim
                  │    └─ navigates { "amount": 15000 } → returns "15000.0"
                  │
                  ├─ textToDouble "15000.0" → 15000.0
                  │
                  ├─ 15000.0 > 10000.0  ✓  TRUE
                  │
                  └─ RuleResult { resultRuleName = "high_amount"
                                , resultMatched  = True
                                , resultAction   = Just (FlagFraud' "Unusually large amount")
                                , resultDetails  = "Rule matched: High value claim"
                                }

determineRiskLevel [matched result with FlagFraud] → CriticalRisk
```

### Output (response body)

```json
{
  "batchResults": [
    {
      "claimIndex": 0,
      "report": {
        "results": [
          {
            "resultRuleName": "high_amount",
            "resultMatched":  true,
            "resultAction":   { "tag": "FlagFraud'", "contents": "Unusually large amount" },
            "resultDetails":  "Rule matched: High value claim"
          }
        ],
        "totalRules":   1,
        "matchedRules": 1,
        "overallRisk":  "CriticalRisk",
        "summary":      "Evaluated 1 rules, 1 matched. Overall risk: CriticalRisk"
      }
    }
  ],
  "totalClaims": 1
}
```

---

## Key Haskell Concepts

| Concept | What it does | Where you see it |
|---|---|---|
| `case … of` | pattern match — like a `switch` but exhaustive | routing, predicate walking |
| `Either L R` | returns success (`Right`) or failure (`Left`) | `loadRules`, `parseRules` |
| `Maybe a` | a value that might be absent (`Just x` or `Nothing`) | field lookup results |
| `map f list` | applies `f` to every item in a list | fanning claims over rules |
| `mapM f list` | like `map` but allows IO side effects | `compileRules` |
| `[Rule]` | a list of Rules | the engine's rule store |
| `TVar` | thread-safe transactional variable | `CompiledRuleCache` |
| Recursive ADT | a type that references itself | `Predicate` tree (And, Or, Not) |
| Record syntax | named fields in a data type (like a struct) | `Rule`, `RuleResult` |
