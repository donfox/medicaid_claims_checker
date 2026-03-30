#!/usr/bin/env python3
"""Generate a PDF version of haskell_engine/README.md."""

from fpdf import FPDF


class ReadmePDF(FPDF):
    def header(self):
        if self.page_no() == 1:
            return  # title page has custom header
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 6, "Haskell Engine - Architecture and Reference", align="C", new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(2)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 10, f"Page {self.page_no()}/{{nb}}", align="C")
        self.set_text_color(0, 0, 0)

    def h1(self, text):
        self.set_font("Helvetica", "B", 18)
        self.cell(0, 10, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(2)

    def h2(self, text):
        self.set_font("Helvetica", "B", 14)
        self.set_fill_color(40, 60, 100)
        self.set_text_color(255, 255, 255)
        self.cell(0, 8, f"  {text}", fill=True, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(3)

    def h3(self, text):
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(40, 60, 100)
        self.cell(0, 7, text, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(1)

    def para(self, text):
        self.set_font("Helvetica", "", 9)
        self.multi_cell(0, 4.5, text)
        self.ln(2)

    def bold_para(self, text):
        self.set_font("Helvetica", "B", 9)
        self.multi_cell(0, 4.5, text)
        self.ln(2)

    def bullet(self, text):
        self.set_font("Helvetica", "", 9)
        x = self.get_x()
        self.cell(6, 4.5, chr(0x2022))
        self.multi_cell(0, 4.5, text)

    def code_block(self, text):
        self.set_font("Courier", "", 7)
        self.set_fill_color(245, 245, 245)
        x = self.get_x()
        w = self.w - self.l_margin - self.r_margin
        lines = text.split("\n")
        # Check if we need a page break
        needed = len(lines) * 3.4 + 4
        if self.get_y() + needed > self.h - 20:
            self.add_page()
        self.rect(x, self.get_y(), w, len(lines) * 3.4 + 2, "F")
        self.ln(1)
        for line in lines:
            self.cell(0, 3.4, "  " + line, new_x="LMARGIN", new_y="NEXT")
        self.ln(3)

    def table_row(self, cols, bold=False, widths=None):
        style = "B" if bold else ""
        self.set_font("Helvetica", style, 7.5)
        if widths is None:
            w = (self.w - self.l_margin - self.r_margin) / len(cols)
            widths = [w] * len(cols)
        if bold:
            self.set_fill_color(40, 60, 100)
            self.set_text_color(255, 255, 255)
        else:
            self.set_fill_color(250, 250, 255)
        for i, col in enumerate(cols):
            self.cell(widths[i], 5.5, col, border=1, fill=True)
        self.set_text_color(0, 0, 0)
        self.ln()

    def hr(self):
        self.set_draw_color(180, 180, 180)
        y = self.get_y()
        self.line(self.l_margin, y, self.w - self.r_margin, y)
        self.ln(3)


pdf = ReadmePDF(orientation="P", unit="mm", format="A4")
pdf.alias_nb_pages()
pdf.set_auto_page_break(auto=True, margin=20)

# ============================================================================
# Title page
# ============================================================================
pdf.add_page()
pdf.ln(30)
pdf.set_font("Helvetica", "B", 28)
pdf.cell(0, 14, "Haskell Engine", align="C", new_x="LMARGIN", new_y="NEXT")
pdf.set_font("Helvetica", "", 16)
pdf.cell(0, 10, "Architecture and Reference", align="C", new_x="LMARGIN", new_y="NEXT")
pdf.ln(10)
pdf.set_draw_color(40, 60, 100)
mid = pdf.w / 2
pdf.line(mid - 40, pdf.get_y(), mid + 40, pdf.get_y())
pdf.ln(10)
pdf.set_font("Helvetica", "I", 10)
pdf.cell(0, 6, "JSON Claims Integrity Project", align="C", new_x="LMARGIN", new_y="NEXT")
pdf.cell(0, 6, "March 2026", align="C", new_x="LMARGIN", new_y="NEXT")

# ============================================================================
# Functional Programming Design
# ============================================================================
pdf.add_page()
pdf.h2("Functional Programming Design")
pdf.para("The rule evaluation engine is written in Haskell, a purely functional language.")
pdf.bullet("Rules are parsed into an AST and evaluated via pattern matching and recursive descent.")
pdf.bullet("Syntax.hs defines the DSL grammar as algebraic data types (ADTs) -- a hallmark FP design.")
pdf.bullet("RuleEngine.hs and SimpleEvaluator.hs compose rule evaluation functionally, with no mutable state.")
pdf.bullet("PolicyCombiner.hs combines rule results using combinators -- a classic FP pattern.")
pdf.ln(2)
pdf.para("The Elixir/Phoenix frontend is also functional: Phoenix LiveView uses immutable state diffs and message-passing, and the claims context uses pipelines (|>) and pure transformations. This split is deliberate -- the Haskell engine handles rule logic (pure, stateless, easily testable) while Elixir handles web and state management. Side effects (DB, HTTP) are pushed to the edges; the rule evaluation core remains pure.")

# ============================================================================
# Big Picture
# ============================================================================
pdf.hr()
pdf.h2("Big Picture")
pdf.code_block("""\
  CLIENT (Phoenix / curl / test script)
          |
          |  POST /api/batch-evaluate
          |  Body: { "rulesText": "...", "claims": [...] }
          v
  +-------------------------------------------------------+
  |                Main.hs  (Warp HTTP server)             |
  |                                                        |
  |  1. Decode JSON body                                   |
  |  2. Split into  rulesText  and  claims[]               |
  +------------+--------------------------+----------------+
               |                          |
               v                          v
       +---------------+          +---------------+
       |  RuleEngine   |          | [Aeson.Value] |
       |  loadRules    |          | (JSON claims) |
       +-------+-------+          +-------+-------+
               |                          |
               |  parseRules              |
               v                          |
       +---------------+                  |
       |   [Rule]      |<-----------------+
       |  (AST list)   |   evaluateSimpleJson
       +-------+-------+   maps each claim over
               |            every Rule in the list
               v
       +-------------------------------+
       |       SimpleEvaluator         |
       |                               |
       |  for each (claim, rule):      |
       |    1. resolve LET bindings    |
       |    2. walk Predicate AST      |
       |    3. lookup JSON fields      |
       |    4. compare values          |
       |    5. return RuleResult       |
       +-------------------------------+
               |
               v
       +-------------------------------+
       |       EvaluationReport        |
       |                               |
       |  * results   : [RuleResult]   |
       |  * riskLevel : Low/Med/High/  |
       |                Critical       |
       |  * summary   : Text           |
       +-------------------------------+
               |
               v
       JSON response back to client""")

# ============================================================================
# Evaluation Pipeline
# ============================================================================
pdf.add_page()
pdf.h2("Evaluation Pipeline")

pdf.h3("Step 1 -- HTTP Request and Routing")
pdf.para("File: app/Main.hs")
pdf.para("The Warp web server receives the POST. pathInfo splits the URL into a list; Haskell's case expression matches it to the right handler -- no framework, just pattern matching.")
pdf.code_block("""\
case pathInfo request of
  ["api", "batch-evaluate"] -> handleBatchEvaluate request respond
  ["api", "evaluate"]       -> handleEvaluate       request respond
  ["api", "compile-rules"]  -> handleCompileRules cache request respond
  ["api", "parse-rule"]     -> handleParseRule      request respond
  ["api", "health"]         -> handleHealth         respond
  _                         -> respond $ responseLBS status400 [] "Not found" """)

pdf.para("The handler decodes the raw HTTP body into a BatchEvaluationRequest:")
pdf.code_block("""\
data BatchEvaluationRequest = BatchEvaluationRequest
  { batchRulesText :: Text          -- the DSL rule program
  , batchClaims    :: [Aeson.Value] -- list of JSON claim objects
  }""")

pdf.hr()
pdf.h3("Step 2 -- Parsing DSL Text into an AST")
pdf.para("File: src/Claims/RuleEngine.hs")
pdf.code_block("""\
loadRules :: Text -> Either String RuleEngine
loadRules rulesText = case parseRules rulesText of
  Left  err   -> Left  ("Parse error: " ++ show err)
  Right rules -> Right (RuleEngine rules)""")
pdf.para("parseRules reads raw DSL text and produces [Rule] -- in-memory Haskell data structures. Either is Haskell's \"success or failure\" type: Left err on failure, Right rules on success. After this step the text is gone; the engine works entirely with the AST.")

pdf.hr()
pdf.h3("Step 3 -- Rule (AST) Structure")
pdf.para("File: src/Claims/Syntax.hs")
pdf.para("A Rule is a Haskell record (like a struct) with five fields:")
pdf.code_block("""\
Rule
 +-- ruleName        : Text       e.g. "high_amount"
 +-- ruleDescription : Text       e.g. "Flag claims over $10,000"
 +-- ruleBindings    : [Binding]  optional LET x = some.field aliases
 +-- ruleCondition   : Predicate  <- the boolean expression tree
 +-- ruleAction      : Action     what to do when condition is true""")
pdf.para("WHEN amount > 10000 THEN FLAG_FRAUD \"large\" becomes:")
pdf.code_block("""\
ruleCondition = GreaterThan
                  (Field "amount")       <- field reference
                  (NumberValue 10000.0)  <- literal number

ruleAction    = FlagFraud "large" """)
pdf.para("Predicate is a tree -- complex rules nest predicates inside each other:")
pdf.code_block("""\
WHEN amount > 10000 AND status = "pending"

         And
        /    \\
 GreaterThan  Equals
 (amount,     (status,
  10000)       "pending")""")

# ============================================================================
# Step 4-5
# ============================================================================
pdf.add_page()
pdf.h3("Step 4 -- Evaluating Each Claim")
pdf.para("File: src/Claims/RuleEngine.hs")
pdf.code_block("""\
evaluateSimpleJson :: RuleEngine -> Aeson.Value -> EvaluationReport
evaluateSimpleJson engine claimDoc =
  let results = map (evaluateRuleSimple claimDoc) (engineRules engine)""")
pdf.para("map f list applies f to every element. Every rule is always evaluated -- there is no short-circuit on first match. All results are collected and determineRiskLevel picks the worst outcome.")
pdf.code_block("""\
rules   = [ rule1,   rule2,   rule3,   ... ]
                |        |        |
                v        v        v
                evaluateRuleSimple claim
                |        |        |
                v        v        v
results = [ result1, result2, result3, ... ]""")

pdf.hr()
pdf.h3("Step 5 -- Walking the Predicate Tree")
pdf.para("File: src/Claims/SimpleEvaluator.hs")
pdf.para("The evaluator uses an EvalEnv (evaluation environment) that carries three pieces of context:")
pdf.code_block("""\
EvalEnv
 +-- envLetBindings : Map Text Text         -- LET aliases
 +-- envScopeVars   : Map Text Aeson.Value  -- named quantifier variables
 +-- envDoc         : Aeson.Value           -- current JSON document context""")
pdf.para("Field resolution checks scope variables first (for named quantifier bindings), then LET bindings, then the document. This enables nested quantifiers to access both inner and outer bound elements -- the key mechanism for first-order predicate calculus equivalence.")
pdf.para("The core evaluateWithEnv function is recursive, pattern-matching on each predicate node:")
pdf.code_block("""\
Predicate node            What the evaluator does
-----------------------   -----------------------------------------
GreaterThan field val     look up field in JSON -> parse as number -> compare
Equals      field val     look up field in JSON -> compare as string
And p1 p2                 evaluate p1 AND evaluate p2  (recurse both)
Or  p1 p2                 evaluate p1 OR  evaluate p2  (recurse both)
Not p                     NOT (evaluate p)              (recurse one)
Between field lo hi       look up field -> check lo <= field <= hi
HasDiagnosis "code"       search diagnosis_codes[*].code in claim
HasProcedure "code"       search procedure_codes/service_lines
Exists (Just x) path p    bind each element to x -> evaluate p
Exists Nothing  path p    shift envDoc to each element -> evaluate p
ForAll (Just x) path p    bind each element to x -> check ALL satisfy p
ForAll Nothing  path p    shift envDoc -> check ALL
IsNull field              field missing or null -> true
HelperCall "is_weekend"   extract date field -> check day-of-week""")

# ============================================================================
# Step 6-7
# ============================================================================
pdf.add_page()
pdf.h3("Step 6 -- JSON Field Lookup")
pdf.para("File: src/Claims/SimpleEvaluator.hs")
pdf.para("Field references are resolved by navigating the JSON object tree using dot-separated path segments. Array elements are accessed by numeric index.")
pdf.code_block("""\
FieldRef in rule DSL      JSON claim structure        Result
------------------------  --------------------------  ----------
Field "amount"            { "amount": 15000 }         "15000"
Field "claim.amount"      { "claim": { "amount": 9 }} "9"
SegmentField "CLM" "01"   { "CLM": { "01": "X" } }   "X"
Field "items.0.price"     { "items": [{"price": 5}] } "5" """)
pdf.para("All JSON leaf values are coerced to Text (plain string) for comparison:")
pdf.code_block("""\
JSON type    Becomes
-----------  ---------------------------
"pending"    "pending"
15000        "15000.0"
true         "true"
null         Nothing  (field treated as missing)""")

pdf.hr()
pdf.h3("Step 7 -- Result and Risk Aggregation")
pdf.para("File: src/Claims/RuleEngine.hs")
pdf.para("Each rule produces a RuleResult:")
pdf.code_block("""\
RuleResult
 +-- resultRuleName : Text          "high_amount"
 +-- resultMatched  : Bool          True / False
 +-- resultAction   : Maybe Action  Just (FlagFraud' "large")  or  Nothing
 +-- resultDetails  : Text          "Rule matched: ..." """)
pdf.para("determineRiskLevel scans all results and picks the worst:")
pdf.code_block("""\
Any FlagFraud or RejectClaim action?     -> CriticalRisk
3 or more rules scored >= 70?            -> HighRisk
1 or 2 rules scored >= 70?              -> MediumRisk
Nothing significant triggered?          -> LowRisk
ApproveClaim only?                       -> LowRisk (does not elevate risk)""")
pdf.para("The final EvaluationReport is serialised to JSON and returned in the HTTP response.")

# ============================================================================
# Rule Storage
# ============================================================================
pdf.add_page()
pdf.h2("Rule Storage")
pdf.para("There are two distinct places rules can live, depending on which API endpoint is used.")

pdf.h3("Storage 1 -- RuleEngine list (per-request, temporary)")
pdf.para("File: src/Claims/RuleEngine.hs")
pdf.code_block("""\
data RuleEngine = RuleEngine
  { engineRules :: [Rule]   -- a plain Haskell list of Rule ASTs
  }""")
pdf.para("Used by /api/batch-evaluate. The DSL text is parsed fresh on every request and stored here for the lifetime of that one request. When the HTTP response is sent the list is discarded -- nothing persists.")

pdf.h3("Storage 2 -- CompiledRuleCache (server-lifetime, persistent)")
pdf.para("File: src/Claims/RuleCache.hs")
pdf.code_block("""\
data CompiledRuleCache = CompiledRuleCache
  { cacheRules :: TVar (Map Text CompiledRule)
  }""")
pdf.para("This map lives for the entire server lifetime, allocated once in main and shared across all requests:")
pdf.code_block("""\
main :: IO ()
main = do
  cache <- newCompiledRuleCache   -- created once
  run 8080 (app cache)            -- shared across all requests""")
pdf.para("Rules enter the cache via /api/compile-rules. Each entry is a CompiledRule:")
pdf.code_block("""\
data CompiledRule = CompiledRule
  { compiledRuleName :: Text
  , compiledFunction :: Aeson.Value -> RuleResult  -- claim in, result out
  , compiledAt       :: UTCTime
  }""")
pdf.para("compiledFunction is a pre-built evaluation function -- the AST is already bound inside it, so there is no re-parsing on each claim. TVar is Haskell's transactional variable; reads and writes are wrapped in atomically, making the cache thread-safe.")
pdf.para("In the cache path, compileRules uses mapM (the IO-capable version of map):")
pdf.code_block("""\
compileRules :: [Rule] -> IO [CompilationResult]
compileRules = mapM compileRule""")
pdf.para("mapM is needed because compileRule has a side effect (recording a timestamp via getCurrentTime), whereas plain map only works with pure functions.")

pdf.h3("Comparison")
w1, w2, w3 = 40, 55, 55
pdf.table_row(["", "RuleEngine list", "CompiledRuleCache"], bold=True, widths=[w1, w2, w3])
pdf.table_row(["File", "RuleEngine.hs", "RuleCache.hs"], widths=[w1, w2, w3])
pdf.table_row(["Lives for", "One request", "Entire server lifetime"], widths=[w1, w2, w3])
pdf.table_row(["Populated by", "/api/batch-evaluate", "/api/compile-rules"], widths=[w1, w2, w3])
pdf.table_row(["Storage type", "[Rule] - plain list", "TVar (Map Text CompiledRule)"], widths=[w1, w2, w3])
pdf.table_row(["Thread safe?", "N/A (request-local)", "Yes - atomically via STM"], widths=[w1, w2, w3])
pdf.table_row(["Re-parses DSL?", "Every request", "No - parsed once"], widths=[w1, w2, w3])

# ============================================================================
# Claim Structure
# ============================================================================
pdf.add_page()
pdf.h2("Claim Structure")
pdf.para("What a decoded medical claim looks like.")

pdf.h3("Example 1 -- Normal / Approved Claim")
pdf.para("Source: claim_normal_approved.json")
pdf.para("A low-value office visit ($150) with a valid authorisation and a known provider. Expected result: APPROVED.")
pdf.code_block("""\
{
  "claim_id": "CLM-NORMAL-001",
  "submission_type": "healthcare_claim_997",
  "provider": {
    "name": "Kansas City Medical Center",
    "npi": "1234567901",
    "type": "Clinic",
    "state": "MO",
    "risk_score": 25,
    "specialty": "Family Medicine"
  },
  "patient": {
    "name": { "first": "Elizabeth", "last": "Wilson" },
    "date_of_birth": "1982-10-12",
    "gender": "Female"
  },
  "diagnosis_codes": [
    { "code": "Z00.00", "description": "General adult exam" }
  ],
  "service_lines": [
    { "procedure_code": "99213", "units": 1, "line_amount": 150.00 }
  ],
  "financial": { "claim_amount": 150.00, "patient_copay": 25.00 }
}""")

pdf.h3("Example 2 -- High-Amount Fraud Trigger")
pdf.para("Source: claim_high_amount_trigger.json")
pdf.para("A $75,000 hospital inpatient claim. Expected result: FLAG_FRAUD.")
pdf.code_block("""\
{
  "claim_id": "CLM-HIGH-AMOUNT-001",
  "claim": { "amount": 75000, "units": 10, "drg_code": "640" },
  "provider": {
    "name": "Premium Medical Center",
    "npi": "1234567890",
    "type": "Hospital",
    "state": "CA"
  },
  "diagnosis_codes": [
    { "code": "E11.9", "description": "Type 2 diabetes mellitus" },
    { "code": "I10",   "description": "Essential hypertension" }
  ],
  "service_lines": [
    { "procedure_code": "99213", "units": 5, "line_amount": 750.00 },
    { "procedure_code": "80053", "units": 1, "line_amount": 85.00 }
  ],
  "financial": { "claim_amount": 75000.00 }
}""")

# ============================================================================
# Aeson Internal Representation
# ============================================================================
pdf.add_page()
pdf.h3("Aeson Internal Representation")
pdf.para("Aeson is the standard Haskell library for JSON parsing and encoding -- the name is a pun on \"Jason\" (the Greek mythological hero) and \"JSON\". It defines a Value type that mirrors the JSON data model exactly, so every JSON document can be represented as a Haskell value without any information loss.")
pdf.para("When the HTTP body is decoded, Aeson produces an Aeson.Value tree. Every JSON type maps to an Aeson constructor:")
pdf.code_block("""\
JSON type          Aeson constructor        Example
-----------------  -----------------------  ----------------------------
{ "key": ... }     Aeson.Object (KeyMap)    the whole claim document
[ ... ]            Aeson.Array  (Vector)    diagnosis_codes, service_lines
"some text"        Aeson.String Text        "CLM-HIGH-AMOUNT-001"
75000              Aeson.Number Scientific  75000
true / false       Aeson.Bool   Bool        true
null               Aeson.Null               null""")

pdf.para("The in-memory representation of claim_high_amount_trigger.json:")
pdf.code_block("""\
Aeson.Object
  "claim_id"      -> Aeson.String "CLM-HIGH-AMOUNT-001"
  "claim"         -> Aeson.Object
                      "amount" -> Aeson.Number 75000
                      "units"  -> Aeson.Number 10
  "provider"      -> Aeson.Object
                      "npi"   -> Aeson.String "1234567890"
                      "state" -> Aeson.String "CA"
  "service_lines" -> Aeson.Array
                      [0] -> Aeson.Object
                              "procedure_code" -> Aeson.String "99213"
                              "units"          -> Aeson.Number 5
                      [1] -> Aeson.Object
                              "procedure_code" -> Aeson.String "80053"
                              "units"          -> Aeson.Number 1
  "financial"     -> Aeson.Object
                      "claim_amount" -> Aeson.Number 75000.0""")

pdf.h3("Field Extraction by DSL Reference")
pdf.para("lookupJsonField splits a dot-path into segments and walks the tree:")
w1, w2, w3 = 55, 55, 40
pdf.table_row(["DSL field reference", "Path walked", "Value returned"], bold=True, widths=[w1, w2, w3])
pdf.table_row(["Field \"claim_id\"", "top level", "\"CLM-HIGH-AMOUNT-001\""], widths=[w1, w2, w3])
pdf.table_row(["Field \"claim.amount\"", "claim -> amount", "\"75000.0\""], widths=[w1, w2, w3])
pdf.table_row(["Field \"provider.state\"", "provider -> state", "\"CA\""], widths=[w1, w2, w3])
pdf.table_row(["Field \"service_lines.0.procedure_code\"", "array index 0 -> field", "\"99213\""], widths=[w1, w2, w3])
pdf.table_row(["Field \"service_lines.1.units\"", "array index 1 -> field", "\"1.0\""], widths=[w1, w2, w3])

# ============================================================================
# End-to-End Example
# ============================================================================
pdf.add_page()
pdf.h2("End-to-End Example")

pdf.h3("Input (POST body)")
pdf.code_block("""\
{
  "rulesText": "RULE high_amount \\"High value claim\\" WHEN amount > 10000
                THEN FLAG_FRAUD \\"Unusually large amount\\";",
  "claims": [
    { "amount": 15000, "provider": "NPI123", "status": "pending" }
  ]
}""")

pdf.h3("Pipeline trace")
pdf.code_block("""\
rulesText  --> parseRules --> Rule { ruleName      = "high_amount"
                                   , ruleCondition = GreaterThan (Field "amount")
                                                                 (NumberValue 10000)
                                   , ruleAction    = FlagFraud "Unusually large amount"
                                   }

claim JSON --> evaluateRuleSimple
                  |
                  +- lookupJsonField (Field "amount") claim
                  |    +- navigates { "amount": 15000 } -> returns "15000.0"
                  |
                  +- textToDouble "15000.0" -> 15000.0
                  |
                  +- 15000.0 > 10000.0  [checkmark]  TRUE
                  |
                  +- RuleResult { resultRuleName = "high_amount"
                                , resultMatched  = True
                                , resultAction   = Just (FlagFraud' "Unusually large amount")
                                , resultDetails  = "Rule matched: High value claim"
                                }

determineRiskLevel [matched result with FlagFraud] -> CriticalRisk""")

pdf.h3("Output (response body)")
pdf.code_block("""\
{
  "batchResults": [
    {
      "claimIndex": 0,
      "report": {
        "results": [
          {
            "resultRuleName": "high_amount",
            "resultMatched":  true,
            "resultAction":   { "tag": "FlagFraud'",
                                "contents": "Unusually large amount" },
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
}""")

# ============================================================================
# Key Haskell Concepts
# ============================================================================
pdf.add_page()
pdf.h2("Key Haskell Concepts")
w1, w2, w3 = 30, 65, 55
pdf.table_row(["Concept", "What it does", "Where you see it"], bold=True, widths=[w1, w2, w3])
pdf.table_row(["case ... of", "pattern match - like a switch but exhaustive", "routing, predicate walking"], widths=[w1, w2, w3])
pdf.table_row(["Either L R", "returns success (Right) or failure (Left)", "loadRules, parseRules"], widths=[w1, w2, w3])
pdf.table_row(["Maybe a", "a value that might be absent (Just x or Nothing)", "field lookup results"], widths=[w1, w2, w3])
pdf.table_row(["map f list", "applies f to every item in a list", "fanning claims over rules"], widths=[w1, w2, w3])
pdf.table_row(["mapM f list", "like map but allows IO side effects", "compileRules"], widths=[w1, w2, w3])
pdf.table_row(["[Rule]", "a list of Rules", "the engine's rule store"], widths=[w1, w2, w3])
pdf.table_row(["TVar", "thread-safe transactional variable", "CompiledRuleCache"], widths=[w1, w2, w3])
pdf.table_row(["Recursive ADT", "a type that references itself", "Predicate tree (And, Or, Not)"], widths=[w1, w2, w3])
pdf.table_row(["Record syntax", "named fields in a data type (like a struct)", "Rule, RuleResult"], widths=[w1, w2, w3])

pdf.ln(10)
pdf.set_font("Helvetica", "I", 8)
pdf.cell(0, 5, "Generated from haskell_engine/README.md -- JSON Claims Integrity project -- March 2026", align="C")

output_path = "/Users/donfox1/Work/JSON_claims_integrity/docs/haskell_engine_readme.pdf"
pdf.output(output_path)
print(f"PDF written to {output_path}")
