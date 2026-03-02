# Database Entity Relationship Diagram (In-Use)

Current Ecto/PostgreSQL schema used by the Phoenix app (`X12FraudWeb.Claims`).

## ERD Diagram

```mermaid
erDiagram
    batches ||--o{ edi_files : "has many"
    rule_catalogue ||--o| business_rules : "name matches (no FK)"

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
```

## Relationship Notes

- `batches` → `edi_files` is the only foreign-key relationship currently in use.
- `rule_catalogue` → `business_rules`: linked by matching `name` field (no database FK). A `rule_catalogue` entry with `entry_type = "BA Rule"` corresponds to a `business_rules` row with the same name.
- `rule_catalogue` is the authoritative registry for all rule types (Default Rule, BA Rule, ML Model). `business_rules` stores the DSL text only for BA Rules.

## Status and Enum Domains (from app changesets)

- `batches.status`: `pending`, `processing`, `completed`, `failed`
- `edi_files.status`: `pending`, `translated`, `syntax_error`, `fraudulent`
- `rule_catalogue.status`: `Active`, `Inactive`
- `rule_catalogue.entry_type`: `Default Rule`, `BA Rule`, `ML Model`

## Future Expansion (Only If Needed)

Keep the current schema lean unless product requirements require additional governance or audit depth.

Suggested incremental order:

1. Rule versioning (`business_rule_versions`)
2. Execution traceability (`claim_decisions`, `rule_execution_log`)
3. Deployment grouping (`rule_sets`, `rule_set_members`)
4. Compliance audit trail (`audit_log`)

Guideline: implement database complexity at the same pace as shipped product behavior.
