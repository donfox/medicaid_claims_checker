# Database Entity Relationship Diagram (In-Use)

Current Ecto/PostgreSQL schema used by the Phoenix app (`X12FraudWeb.Claims`).

## ERD Diagram

```mermaid
erDiagram
    batches ||--o{ edi_files : "has many"

    batches {
        bigint id PK
        string batch_id UK "NOT NULL"
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

    business_rules {
        bigint id PK
        string name UK "NOT NULL"
        text rule_text "NOT NULL"
        boolean active "NOT NULL, default true"
        utc_datetime inserted_at
        utc_datetime updated_at
    }
```

## Relationship Notes

- `batches` → `edi_files` is the only foreign-key relationship currently in use.
- `business_rules` is actively used by the app but is currently standalone (no FK relationship).

## Status Domains (from app changesets)

- `batches.status`: `pending`, `processing`, `completed`, `failed`
- `edi_files.status`: `pending`, `translated`, `syntax_error`, `fraudulent`

## Future Expansion (Only If Needed)

Keep the current schema lean unless product requirements require additional governance or audit depth.

Suggested incremental order:

1. Rule versioning (`business_rule_versions`)
2. Execution traceability (`claim_decisions`, `rule_execution_log`)
3. Deployment grouping (`rule_sets`, `rule_set_members`)
4. Compliance audit trail (`audit_log`)

Guideline: implement database complexity at the same pace as shipped product behavior.
