# Medicaid Claims Checker Web Frontend

Phoenix LiveView application providing the user interface for claim ingestion, rule management, batch evaluation, and fraud detection scoring.

## Features

- Scheduled X12 file ingestion via configured SFTP/HTTP sources with cron or interval-based schedules
- Manual file upload with in-process X12/EDI-to-JSON translation (supports `.json`, `.x12`, `.edi`, `.zip`)
- NPPES provider database with configurable auto-refresh (weekly by default)
- NPPES pre-validation: claims with unrecognised provider NPIs are hard-rejected before rule evaluation
- Business rule catalogue with type-based management (Default Rules, BA Rules, ML Models)
- In-browser DSL editor with real-time syntax validation and redundancy detection
- Batch evaluation history with per-claim risk level and matched rule details
- Risk-level scoring display (CriticalRisk, HighRisk, MediumRisk, LowRisk)

## Pages

| Route | LiveView | Purpose |
|---|---|---|
| `/` | `FetchSourceLive.Index` | Fetch source and schedule management, NPPES config and refresh, manual file upload, batch history |
| `/rules` | `RuleLive.Index` | DSL editor, rule evaluation, redundancy checking |

Development-only routes: `/dev/dashboard` (Phoenix LiveDashboard), `/dev/mailbox` (Swoosh).

## API Endpoints

| Route | Purpose |
|---|---|
| `GET /api/health` | Liveness check |
| `GET /api/fetch-config` | Return active fetch source configuration (JSON) |

## Database Tables

### `batches`

| Column | Type | Notes |
|---|---|---|
| `batch_id` | string | Unique batch identifier |
| `batch_name` | string | Human-readable label (nullable) |
| `source` | string | Origin description (e.g. `scheduled:sftp_source`, `manual_upload`) |
| `file_count` | integer | Number of claims in batch |
| `status` | string | `pending` / `processing` / `completed` / `failed` |
| `started_at` | utc_datetime | When batch processing began |
| `completed_at` | utc_datetime | When batch processing finished |

### `edi_files`

| Column | Type | Notes |
|---|---|---|
| `filename` | string | Claim filename |
| `file_path` | string | Storage path or ingest URI |
| `json_output` | jsonb | Translated claim JSON + evaluation report |
| `status` | string | `pending` / `translated` / `syntax_error` / `fraudulent` |
| `error_message` | text | nullable |
| `error_details` | jsonb | nullable |
| `processed_at` | utc_datetime | nullable |
| `batch_id` | bigint FK | References `batches`, cascade delete |

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

### `nppes_providers`

| Column | Type | Notes |
|---|---|---|
| `npi` | string PK | National Provider Identifier |
| `entity_type` | integer | 1 = individual, 2 = organisation |
| `provider_name` | string | |
| `credential` | string | nullable |
| `state` | string | nullable |
| `taxonomy` | string | Primary taxonomy code (nullable) |
| `enumeration_date` | date | nullable |
| `deactivation_date` | date | nullable |
| `reactivation_date` | date | nullable |
| `last_update_date` | date | nullable |

Indexed on `state` and `deactivation_date`.

### `fetch_sources`

| Column | Type | Notes |
|---|---|---|
| `name` | string UK | Unique display name |
| `uri` | string | SFTP or HTTP URI |
| `source_type` | string | `sftp` / `http` / `local` / `databricks` |
| `enabled` | boolean | Default true |
| `credentials` | jsonb | Optional `username` / `password` (nullable) |

### `fetch_schedules`

| Column | Type | Notes |
|---|---|---|
| `fetch_source_id` | bigint FK | References `fetch_sources`, cascade delete |
| `cron_expression` | string | Cron schedule (nullable, mutually exclusive with interval) |
| `interval_seconds` | integer | Polling interval (nullable) |
| `enabled` | boolean | Default true |

### `nppes_refresh_config`

| Column | Type | Notes |
|---|---|---|
| `auto_refresh` | boolean | Default true |
| `interval_seconds` | integer | Default 604800 (7 days) |
| `download_url` | string | CMS NPPES zip download URL |
| `last_refresh_at` | utc_datetime | nullable |
| `last_row_count` | integer | Providers imported in last refresh |
| `last_status` | string | `never` / `running` / `completed` / `failed` |
| `last_error` | text | nullable |

## Backend Integration

The frontend calls the Haskell engine at `http://localhost:8080` via HTTPoison.

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/parse-rule` | POST | Validate DSL syntax without execution |
| `/api/compile-rules` | POST | Parse and cache a full ruleset before evaluation |
| `/api/batch-evaluate` | POST | Evaluate claims against active rules (chunked at 200 claims/request) |
| `/api/check-redundancy` | POST | Detect overlap between a candidate rule and existing rules |

Request payloads are built by `PayloadBuilder` (`lib/medicaid_claims_checker_web/live/rule_live/payload_builder.ex`).

## Setup

Prerequisites: Elixir >= 1.15, PostgreSQL.

```bash
cd phoenix_web
mix setup        # deps.get, ecto.create, ecto.migrate, seeds, assets
```

Seed data loads 17 catalogue entries (Default Rules, BA Rules, ML Models) with matching DSL text in `business_rules`.

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
