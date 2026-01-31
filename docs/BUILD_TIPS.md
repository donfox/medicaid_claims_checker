# Build Optimization Tips

## Why Is Haskell Slow to Build?

Haskell compilation is notoriously slow because:
1. **First build**: Compiles 100+ dependencies from scratch (10-20 minutes typical)
2. **Type checking**: Haskell's type checker is very thorough
3. **Optimization**: Even with `-O0`, there's overhead
4. **Linking**: Final executable linking takes time

## Speed Up Development Builds

### 1. Disable Optimizations (Already Done)
The cabal file now uses `-O0` (no optimizations) for development:
```bash
cd haskell_engine
stack build --ghc-options="-O0"
```

### 2. Use `--fast` Flag
```bash
stack build --fast
```

This skips optimization passes, reducing build time significantly.

### 3. First Build is Slowest
- **First build**: 10-20 minutes (compiling all dependencies)
- **Subsequent builds**: 10-30 seconds (only changed files)
- **Full rebuild**: 2-5 minutes

### 4. Skip Testing During Development
```bash
stack build --test --no-run-tests
# Or just:
stack build
```

### 5. Use Incremental Compilation
Stack caches built files, so only changed modules recompile.

## Production vs Development

### Development Build (Current)
```bash
stack build --fast        # 30 seconds - 2 minutes
```

### Production Build
```bash
stack build --copy-bins   # 5-10 minutes with optimizations
```

## What You're Actually Building

The dependencies include:
- **parsec** - Parser combinator library
- **aeson** - JSON parsing and serialization
- **wai/warp** - Web server framework
- **http-types** - HTTP definitions
- **text** - String handling
- **bytestring** - Binary data
- **containers** - Data structures
- **scientific** - Number parsing

Each of these has multiple transitive dependencies. The good news: this only happens once!

## Faster Workflow

1. **Initial setup** (5-10 minutes one-time):
   ```bash
   cd haskell_engine
   stack build --fast
   ```

2. **Development** (iterative, very fast):
   ```bash
   # Make code changes, then:
   stack build --fast      # Usually 10-30 seconds
   stack run               # Run the server
   ```

3. **Testing**:
   ```bash
   stack test --fast
   ```

## Alternative: Use Pre-built Docker Image

If you really want instant startup, use Docker with pre-built images:
```dockerfile
FROM haskell:9.2.8
WORKDIR /app
COPY . .
RUN stack install
CMD ["stack", "run"]
```

Then:
```bash
docker build -t x12-dsl .
docker run -p 8080:8080 x12-dsl
```

## Cache Issues

If builds are still slow, clear the cache:
```bash
cd haskell_engine
stack clean
rm -rf .stack-work
stack build --fast
```

Then future builds will be fast again.

## Benchmark Times (Typical)

| Scenario | Time |
|----------|------|
| First-ever build | 15 minutes |
| Full clean build | 5-10 minutes |
| Change one file | 20-40 seconds |
| Change many files | 1-3 minutes |
| `stack build --fast` | 10-30 seconds |
| Server startup | <1 second |

## The Phoenix Frontend Builds Much Faster!

```bash
cd phoenix_web
mix compile              # 5-15 seconds
mix phx.server          # Instant with hot reload
```

You can develop the front-end while the Haskell backend builds in the background.

## Recommended Development Workflow

**Terminal 1** - Build and run Haskell (once):
```bash
cd haskell_engine
stack build --fast
stack run
```

**Terminal 2** - Work on Phoenix (fast iterations):
```bash
cd phoenix_web
mix phx.server
```

**Terminal 3** - Make changes, test, iterate

The Haskell part doesn't change often. Focus on the web UI where iteration is fast!
