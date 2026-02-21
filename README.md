# JSON Claims Integrity

A fraud detection system for JSON claim payloads using a custom DSL (Domain-Specific Language) rule engine.

## What the DSL Means

This project uses a domain-specific language (DSL) to express medical-claim fraud and validation rules in business-friendly syntax.
The DSL is parsed and compiled into Haskell functions, which are then executed against JSON claim payloads to produce rule decisions and actions.
In short, the DSL defines the rule logic, and Haskell provides the compiler and runtime that apply that logic to each claim.

## Architecture

- **Haskell Backend** — DSL parser, compiler, and rule evaluation engine (port 8080)
- **Phoenix Frontend** — Web UI for managing and testing fraud detection rules (port 4000)

Note: some internal module/package names still include "X12" for historical reasons, but current BA workflows run on JSON claim payloads.

## Quick Start

```bash
./start.sh              # Start both services
./start.sh --install    # Install dependencies and start
./start.sh --force-kill-ports  # Kill conflicting listeners on 4000/8080, then start
./start.sh --help       # See all options
```

## VS Code Tasks

From the repository root, run the default Haskell tasks in VS Code (Build/Test/Watch). The tasks are configured to execute in `haskell_engine`, so no manual directory change is needed.

## License

Proprietary — All rights reserved. See the `LICENSE` file for full terms.

## Author

**Don Fox** — donfox1@mac.com

---

Copyright (c) 2024-2026 Don Fox. All rights reserved.
