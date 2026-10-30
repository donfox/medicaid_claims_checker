# Database Entity Relationship Diagram

The PostgreSQL tables of the Phoenix app, as created by its migrations
(`phoenix_web/priv/repo/migrations/`). Oban's own job tables (`oban_jobs`,
`oban_peers`) and Ecto's `schema_migrations` are left out.

## Claims and rules

```mermaid
erDiagram
    batches ||--o{ edi_files : "has many"
    batches ||--o{ submitted_files : "built from"
    rule_catalogue ||--o| business_rules : "name matches (no FK)"

    batches {
        bigint id PK
        string batch_id UK "NOT NULL"
        string batch_name "nullable"
        string source
        integer file_count "NOT NULL"
        string status "NOT NULL, default pending"
        jsonb_array duplicates "NOT NULL, default []"
        utc_datetime started_at
        utc_datetime completed_at
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    edi_files {
        bigint id PK
        bigint batch_id FK "NOT NULL, cascade delete"
        string filename "NOT NULL"
        string file_path "NOT NULL"
        jsonb json_output "translated claim, nullable"
        jsonb evaluation_report "nullable"
        string claim_fingerprint "nullable"
        string status "NOT NULL, default pending"
        text error_message "nullable"
        jsonb error_details "nullable"
        utc_datetime processed_at "nullable"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    submitted_files {
        bigint id PK
        bigint batch_id FK "NOT NULL, cascade delete"
        string sha256 UK "NOT NULL"
        string filename "NOT NULL"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    rule_catalogue {
        bigint id PK
        string name UK "NOT NULL"
        text description "nullable"
        string entry_type "NOT NULL: Default Rule|BA Rule|ML Model"
        string status "NOT NULL, default Active: Active|Inactive|Retired"
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
```

## Ingestion and provider data

```mermaid
erDiagram
    fetch_sources ||--o{ fetch_schedules : "has many"
    fetch_sources ||--o{ fetched_files : "has picked up"

    fetch_sources {
        bigint id PK
        string name UK "NOT NULL"
        string uri "NOT NULL"
        string source_type "NOT NULL"
        boolean enabled "NOT NULL, default true"
        bytea credentials "encrypted, nullable"
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

    fetched_files {
        bigint id PK
        bigint fetch_source_id FK "NOT NULL, cascade delete"
        string filename "NOT NULL"
        string sha256 "NOT NULL"
        utc_datetime inserted_at
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
        date dropped_on "nullable"
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

## Accounts and settings

```mermaid
erDiagram
    users ||--o{ users_tokens : "has many"

    users {
        bigint id PK
        citext email UK "NOT NULL"
        citext username UK "nullable"
        string first_name "nullable"
        string last_name "nullable"
        string hashed_password "nullable"
        utc_datetime confirmed_at "nullable"
        boolean is_admin "NOT NULL, default false"
        boolean active "NOT NULL, default true"
        utc_datetime history_cleared_at "nullable"
        utc_datetime inserted_at
        utc_datetime updated_at
    }

    users_tokens {
        bigint id PK
        bigint user_id FK "NOT NULL, cascade delete"
        bytea token "NOT NULL"
        string context "NOT NULL: session|password_setup"
        string sent_to "nullable"
        utc_datetime authenticated_at "nullable"
        utc_datetime inserted_at
    }

    app_settings {
        string key PK "NOT NULL"
        boolean registration_open "NOT NULL, default true"
        utc_datetime inserted_at
        utc_datetime updated_at
    }
```

## Relationships

All foreign keys delete in cascade: removing the parent row removes its children.

| Parent | Child | Meaning |
|---|---|---|
| `batches` | `edi_files` | One row per claim in the batch. |
| `batches` | `submitted_files` | The files the batch was built from. |
| `fetch_sources` | `fetch_schedules` | When the source is polled (cron or interval). |
| `fetch_sources` | `fetched_files` | Files the source has already picked up. |
| `users` | `users_tokens` | Log-in sessions and password-setup links. |

`rule_catalogue` and `business_rules` are linked by matching `name`, with **no
foreign key**: a catalogue entry with `entry_type = "BA Rule"` has a
`business_rules` row of the same name holding its DSL text.

## What each table holds

### Claims and rules

- **`batches`**: one row per upload or scheduled fetch: source, claim count,
  status and timestamps. `duplicates` lists each claim or file refused as
  already submitted, naming the earlier submission.
- **`edi_files`**: one row per claim. `json_output` is the translated claim as
  ingested and is never overwritten; `evaluation_report` is the engine's report
  from the latest evaluation. `claim_fingerprint` is the SHA-256 of the claim
  without its X12 envelope, used to spot the same claim in a different file.
- **`submitted_files`**: every file a batch was built from, keyed by the
  SHA-256 of its bytes (unique), so a file already received is refused.
- **`rule_catalogue`**: the registry of every rule entry (Default Rule, BA
  Rule, ML Model) with its description, status (Active, Inactive or Retired)
  and what may be done with it (edited, removed).
- **`business_rules`**: the DSL text of each BA rule and whether it is active
  in evaluation.

### Ingestion and provider data

- **`fetch_sources`**: where claim files are fetched from (SFTP, HTTP, local
  or Databricks). `credentials` is encrypted with the app's Cloak key.
- **`fetch_schedules`**: when each source is polled.
- **`fetched_files`**: files a source has already picked up, unique by
  source, name and SHA-256, so a re-fetched unchanged file is skipped; the
  same name with new content is a new file.
- **`nppes_providers`**: the imported NPPES registry used to check provider
  NPIs. `dropped_on` is the date of the first full import an NPI was missing
  from; dropped NPIs are kept so late claims can still be checked.
- **`nppes_refresh_config`**: one row: the NPPES download address, refresh
  interval (default 7 days) and the last refresh's time, status and row count.

### Accounts and settings

- **`users`**: accounts. Log-in is by email or username. `hashed_password`
  is empty for accounts made before password registration; an admin gives
  those users a password link (see [ADMIN_GUIDE.md](ADMIN_GUIDE.md)).
  `history_cleared_at` hides older batches from that user's Batch History
  without deleting them.
- **`users_tokens`**: hashed tokens. `session` tokens keep a user logged in
  (14 days); `password_setup` tokens back one-time password links (3 days).
  `sent_to` records the user's email when the token was made, so a token stops
  working if the email changes.
- **`app_settings`**: app-wide switches, today only whether registration is
  open.

## Notes

- Columns shown as `jsonb` hold JSON; `duplicates` is an array of JSON objects.
- `email` and `username` are case-insensitive (`citext`).
- Some relationships, such as catalogue entry to BA rule, are kept by the app
  rather than by database constraints.
