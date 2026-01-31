# Development Guide

## Quick Start

### Prerequisites
- GHC >= 9.2 with Stack
- Elixir >= 1.15 with Mix
- Node.js >= 18 (for Phoenix assets)

### Installation & Setup

```bash
# Clone or navigate to project
cd x12_fraud_dsl

# Run setup script
./setup.sh
```

### Running the Application

**Terminal 1 - Start Haskell Backend (port 8080):**
```bash
./start_backend.sh
# Or manually:
cd haskell_engine && stack run
```

**Terminal 2 - Start Phoenix Frontend (port 4000):**
```bash
./start_frontend.sh
# Or manually:
cd phoenix_web && mix phx.server
```

Open browser to `http://localhost:4000/rules`

## Project Structure

```
x12_fraud_dsl/
├── haskell_engine/          # DSL engine with HTTP server
│   ├── src/X12/DSL/
│   │   ├── Syntax.hs        # AST definition
│   │   ├── Parser.hs        # Parsec-based parser
│   │   ├── Evaluator.hs     # Predicate evaluation
│   │   ├── X12Types.hs      # Document types
│   │   └── RuleEngine.hs    # Evaluation orchestration
│   ├── app/Main.hs          # HTTP server
│   ├── test/Spec.hs         # Unit tests
│   ├── x12-fraud-dsl.cabal  # Cabal manifest
│   ├── stack.yaml           # Stack configuration
│   └── .gitignore
│
├── phoenix_web/             # Web UI
│   ├── lib/x12_fraud_web_web/
│   │   ├── components/      # LiveView components
│   │   ├── live/            # LiveView modules
│   │   ├── router.ex        # Routes
│   │   └── endpoint.ex
│   ├── assets/              # CSS, JS
│   ├── priv/                # Translations, static
│   ├── mix.exs              # Elixir manifest
│   ├── mix.lock             # Dependency lock
│   └── .gitignore
│
├── examples/
│   ├── sample_rules.dsl     # Comprehensive examples
│   └── simple_rules.dsl     # Learning examples
│
├── setup.sh                 # Installation script
├── start_backend.sh         # Start Haskell server
├── start_frontend.sh        # Start Phoenix server
│
├── README.md                # Project overview
├── SYNTAX_GUIDE.md          # DSL syntax reference
├── ARCHITECTURE.md          # Technical architecture
└── DEVELOPMENT.md           # This file
```

## Development Workflow

### Adding a New DSL Feature

#### 1. Update Syntax (if needed)
Edit `haskell_engine/src/X12/DSL/Syntax.hs`:
```haskell
data MyNewFeature = MyNewFeature { ... }
  deriving (Show, Eq, Generic)

instance ToJSON MyNewFeature
instance FromJSON MyNewFeature
```

#### 2. Update Parser
Edit `haskell_engine/src/X12/DSL/Parser.hs`:
```haskell
myNewFeatureParser :: Parser MyNewFeature
myNewFeatureParser = do
  -- parsing logic
```

#### 3. Update Evaluator
Edit `haskell_engine/src/X12/DSL/Evaluator.hs`:
```haskell
evaluatePredicate doc (MyNewFeature ...) = 
  -- evaluation logic
```

#### 4. Add Tests
Edit `haskell_engine/test/Spec.hs`:
```haskell
it "handles my new feature" $ do
  let input = "..."
  parseRule input `shouldSatisfy` isRight
```

#### 5. Test Locally
```bash
cd haskell_engine
stack test
stack build
```

### Adding a New Operator

Example: Adding a `BETWEEN` operator

1. **Syntax.hs** - Add to Predicate type:
```haskell
| Between FieldRef Value Value
```

2. **Parser.hs** - Add parsing rule:
```haskell
predicateBetween :: Parser Predicate
predicateBetween = do
  field <- fieldRef
  _ <- string "BETWEEN"
  val1 <- valueParser
  _ <- string "AND"
  val2 <- valueParser
  return $ Between field val1 val2
```

3. **Evaluator.hs** - Add evaluation:
```haskell
evaluatePredicate doc (Between field v1 v2) =
  case (lookupField field doc, v1, v2) of
    (Just fVal, NumberValue n1, NumberValue n2) ->
      case textToDouble fVal of
        Just n -> n >= n1 && n <= n2
        Nothing -> False
    _ -> False
```

4. **Test** - Add test case in Spec.hs

5. **Update documentation** - Add to SYNTAX_GUIDE.md

## Testing

### Haskell Tests
```bash
cd haskell_engine

# Run all tests
stack test

# Run specific test
stack test --test-arguments "-m PATTERN"

# Run with coverage
stack test --coverage
```

### Manual Testing via API

```bash
# Parse a rule
curl -X POST http://localhost:8080/api/parse-rule \
  -H "Content-Type: application/json" \
  -d '{"ruleText": "RULE test \"Test\" WHEN field = \"value\" THEN FLAG_FRAUD \"test\";"}'

# Evaluate a rule
curl -X POST http://localhost:8080/api/evaluate \
  -H "Content-Type: application/json" \
  -d '{
    "rules": "RULE test \"Test\" WHEN amount > 100.0 THEN FLAG_FRAUD \"high\";" ,
    "document": {"docInterchanges": [...]}
  }'

# Health check
curl http://localhost:8080/api/health
```

### Phoenix Testing
```bash
cd phoenix_web

# Run tests
mix test

# Run with coverage
mix test --cover
```

## Debugging

### Haskell Backend

**Stack Trace:**
```bash
cd haskell_engine
stack run --ghc-options -v
```

**Interactive REPL:**
```bash
cd haskell_engine
stack ghci

> :load src/X12/DSL/Parser.hs
> parseRule "RULE test \"Test\" WHEN ..."
```

**Debug Output:**
Add to Haskell code:
```haskell
import Debug.Trace
evaluateSomething x = trace ("Debug: " ++ show x) $ ...
```

### Phoenix Frontend

**IEx Console:**
```bash
cd phoenix_web
iex -S mix phx.server

> HTTPoison.get("http://localhost:8080/api/health")
```

**Browser DevTools:**
- F12 to open
- Network tab for HTTP requests
- Console for JavaScript errors
- Application tab for storage

## Common Tasks

### Create New Rule Examples

Add to `examples/sample_rules.dsl`:
```
-- Your rule name
RULE rule_identifier "Human-readable description"
WHEN <predicate>
THEN <action>;
```

### Update Dependencies

**Haskell:**
```bash
cd haskell_engine

# Add new dependency to cabal file
# Then:
stack build
stack lock
```

**Phoenix:**
```bash
cd phoenix_web

# Add to mix.exs, then:
mix deps.get
```

### Build for Production

**Haskell:**
```bash
cd haskell_engine
stack build --copy-bins --local-bin-path ./bin
```

**Phoenix:**
```bash
cd phoenix_web
mix phx.digest
mix release
```

## Troubleshooting

### "Port already in use"
If port 4000 or 8080 are already used:

**Phoenix** - Edit `phoenix_web/config/dev.exs`:
```elixir
http: [ip: {127, 0, 0, 1}, port: 4001],
```

**Haskell** - Edit `haskell_engine/app/Main.hs`:
```haskell
main = do
  putStrLn "Starting on port 8081..."
  run 8081 app
```

### Build Failures

**Clear cache:**
```bash
# Haskell
cd haskell_engine
stack clean
rm -rf .stack-work

# Phoenix
cd phoenix_web
mix clean
rm -rf deps _build
```

**Update dependencies:**
```bash
# Haskell
cd haskell_engine
stack update
stack build --dependencies-only

# Phoenix
cd phoenix_web
mix deps.get
mix deps.update
```

### Parsing Issues

Test with simple rule first:
```haskell
> parseRule "RULE test \"test\" WHEN TRUE THEN FLAG_FRAUD \"test\";"
```

Check:
1. String literals use double quotes
2. Semicolon at end
3. No typos in keywords
4. Balanced parentheses

## Performance Tips

### Rule Optimization
1. Use AND before OR (short-circuit)
2. Put most restrictive conditions first
3. Use COUNT for simple quantification
4. Avoid regex MATCHES if possible

### Document Structure
1. Pre-parse X12 documents once
2. Cache field lookups
3. Use indexed lookups when possible

## Contributing Guidelines

1. **Code Style**
   - Haskell: Use `hindent` for formatting
   - Elixir: Use `mix format`

2. **Testing**
   - All new features need tests
   - Maintain >80% code coverage
   - Update SYNTAX_GUIDE.md for user-facing changes

3. **Documentation**
   - Update README.md for major changes
   - Add comments for complex logic
   - Include examples in docstrings

4. **Commits**
   - One feature per commit
   - Descriptive commit messages
   - Reference issue numbers if applicable

## Resources

- [Parsec Documentation](http://hackage.haskell.org/package/parsec)
- [Phoenix LiveView Guide](https://hexdocs.pm/phoenix_live_view/)
- [X12 837P Specification](https://www.x12.org/)
- [Haskell Book](https://haskellbook.com/)
- [Learn Elixir](https://elixir-lang.org/learning.html)

## Contact & Support

For questions or issues:
1. Check existing issues in repository
2. Review SYNTAX_GUIDE.md and ARCHITECTURE.md
3. Create a new issue with detailed description
4. Contact team lead for architectural questions
