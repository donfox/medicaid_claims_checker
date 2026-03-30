# Medicaid Claims Checker Web Frontend

Phoenix LiveView application providing the user interface for rule management, batch claim evaluation, and fraud detection scoring.

## Features

- Batch claim evaluation with JSON file upload
- Business rule catalog with type-based management (Default Rules, BA Rules, ML Models)
- In-browser DSL editor with real-time syntax validation
- Redundancy detection before saving new or edited rules
- Risk-level scoring display (Critical, High, Medium, Low)
- Result filtering and JSON export

## Pages

| Route | LiveView | Purpose |
|---|---|---|
| `/` and `/rules` | `RuleLive.Index` | DSL editor, file upload, batch evaluation, results display |
| `/catalogue` | `RuleCatalogueLive.Index` | Rule registry: add, toggle, delete catalog entries |

Development-only routes: `/dev/dashboard` (Phoenix LiveDashboard), `/dev/mailbox` (Swoosh).

## Database Tables

### `rule_catalogue`

| Column | Type | Notes |
|---|---|---|
| `name` | string | Unique, 2-120 chars |
| `description` | text | Plain-English summary |
| `entry_type` | string | `"Default Rule"` / `"BA Rule"` / `"ML Model"` |
| `status` | string | `"Active"` / `"Inactive"` (default Active) |
| `editable` | boolean | Whether DSL text can be edited in UI |
| `removable` | boolean | Whether the entry can be deleted |
| `redundant` | boolean | Flagged when overlapping another rule |
| `db_access` | boolean | Requires live DB query |

### `business_rules`

| Column | Type | Notes |
|---|---|---|
| `name` | string | Unique, matches `rule_catalogue.name` |
| `rule_text` | text | Raw DSL text sent to Haskell engine |
| `active` | boolean | Soft disable flag (default true) |

## Backend Integration

The frontend calls the Haskell engine at `http://localhost:8080` via HTTPoison.

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/parse-rule` | POST | Validate DSL syntax without execution |
| `/api/compile-rules` | POST | Parse and cache a full ruleset before evaluation |
| `/api/batch-evaluate` | POST | Evaluate claims against active rules |
| `/api/check-redundancy` | POST | Detect overlap between a candidate rule and existing rules |

Request payloads are built by `PayloadBuilder` (`lib/medicaid_claims_checker_web/live/rule_live/payload_builder.ex`).

## Setup

Prerequisites: Elixir >= 1.15, PostgreSQL.

```bash
cd phoenix_web
mix setup        # deps.get, ecto.create, ecto.migrate, seeds, assets
```

Seed data loads 17 catalog entries (Default Rules, BA Rules, ML Models) with matching DSL text in `business_rules`.

## Running

From the repository root:

```bash
./start.sh --frontend       # port 4000, background
./start.sh --frontend -f    # port 4000, foreground
```

Or directly:

```bash
cd phoenix_web
mix phx.server              # http://localhost:4000
```

Health check: `GET http://localhost:4000/api/health`

## License

Proprietary — All rights reserved.

No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.

See the repository root LICENSE file for full terms.
