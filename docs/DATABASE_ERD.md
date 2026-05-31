# Database Entity Relationship Diagram (In Use)

This document describes the current PostgreSQL / Ecto schema used by the Phoenix application in `MedicaidClaimsChecker.Claims`.

## ERD Diagram

```mermaid
erDiagram
    batches ||--o{ edi_files : "has many"
    rule_catalogue ||--o| business_rules : "name matches (no FK)"
    fetch_sources ||--o{ fetch_schedules : "has many"

    batches {
        bigint id PK
        string batch_id UK "NOT NULL"
        string batch_name "nullable"
        string source
        integer file_count "NOT NULL"
        string status "NOT NULL, default pending"
        utc_datetime started_at
        utc_datetime completed_at
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    edi_files {
        bigint id PK
        string filename "NOT NULL"
        string file_path "NOT NULL"
        map json_output "JSONB, nullable"
        string status "NOT NULL, default pending"
        text error_message "nullable"
        map error_details "JSONB, nullable"
        utc_datetime processed_at "nullable"
        bigint batch_id FK "NOT NULL, cascade delete"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    rule_catalogue {
        bigint id PK
        string name UK "NOT NULL"
        text description "nullable"
        string entry_type "NOT NULL: Default Rule|BA Rule|ML Model"
        string status "NOT NULL, default Active: Active|Inactive"
        boolean editable "NOT NULL, default false"
        boolean removable "NOT NULL, default false"
        boolean redundant "NOT NULL, default false"
        boolean db_access "NOT NULL, default false"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    business_rules {
        bigint id PK
        string name UK "NOT NULL"
        text rule_text "NOT NULL"
        boolean active "NOT NULL, default true"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    nppes_providers {
        string npi PK "NOT NULL"
        integer entity_type "NOT NULL"
        string provider_name "NOT NULL"
        string credential "nullable"
        string state "nullable"
        string taxonomy "nullable"
        date enumeration_date "nullable"
        date deactivation_date "nullable"
        date reactivation_date "nullable"
        date last_update_date "nullable"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    fetch_sources {
        bigint id PK
        string name UK "NOT NULL"
        string uri "NOT NULL"
        string source_type "NOT NULL"
        boolean enabled "NOT NULL, default true"
        map credentials "JSONB, nullable"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    fetch_schedules {
        bigint id PK
        bigint fetch_source_id FK "NOT NULL, cascade delete"
        string cron_expression "nullable"
        integer interval_seconds "nullable"
        boolean enabled "NOT NULL, default true"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    nppes_refresh_config {
        bigint id PK
        boolean auto_refresh "NOT NULL, default true"
        integer interval_seconds "NOT NULL, default 604800"
        string download_url "NOT NULL"
        utc_datetime last_refresh_at "nullable"
        integer last_row_count "NOT NULL, default 0"
        string last_status "NOT NULL, default never"
        text last_error "nullable"
        utc_datetime inserted_at
        utc_datetime updated_at
    }
```

## Relationship Notes

### `batches` to `edi_files`

- This is the main foreign-key relationship in the claims pipeline.
- One batch can contain many `edi_files`.
- `edi_files.batch_id` is required and deletes cascade when the parent batch is removed.

### `fetch_sources` to `fetch_schedules`

- This is a foreign-key relationship with cascade delete.
- One fetch source can have multiple schedules.
- Scheduling can be cron-based or interval-based.

### `rule_catalogue` to `business_rules`

- These tables are related by matching `name` values.
- There is **no database foreign key** between them.
- A `rule_catalogue` row with `entry_type = "BA Rule"` corresponds to a `business_rules` row with the same `name`.

## Table Roles

### `rule_catalogue`

`rule_catalogue` is the authoritative registry for all rule-entry types:

- `Default Rule`
- `BA Rule`
- `ML Model`

It stores metadata such as:

- display name
- description
- status
- editability
- removability
- redundancy flag
- database-access flag

### `business_rules`

`business_rules` stores the raw DSL text for BA-authored rules plus the active flag used during evaluation.

### `batches`

`batches` stores one row per ingestion or evaluation batch, including source, counts, and lifecycle timestamps.

### `edi_files`

`edi_files` stores one row per translated claim file and captures status, translated JSON, evaluation output, and any error details.

### `nppes_providers`

`nppes_providers` stores the imported NPPES provider snapshot used during NPI pre-validation.

### `fetch_sources`

`fetch_sources` stores remote or local input locations such as SFTP, HTTP, local, or Databricks sources.

### `fetch_schedules`

`fetch_schedules` stores polling schedules attached to fetch sources.

### `nppes_refresh_config`

`nppes_refresh_config` stores the state of NPPES auto-refresh, including interval, last status, row count, and any last error.

## Operational Notes

- `json_output` and `error_details` are stored as `JSONB`.
- Some important relationships are enforced in application logic rather than database constraints.
- The schema mixes workflow state, rule metadata, translated claim content, and reference data.
- The `rule_catalogue` / `business_rules` split is intentional: one table manages the catalogue entry, and the other stores the BA DSL text.
