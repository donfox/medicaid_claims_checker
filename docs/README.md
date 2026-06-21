# Documentation Guide

> **eMRTS Intern Project:** This project is one of four instructional projects developed as part of intern training at eMRTS.

This folder is split into two groups:

- **Core docs**: the current, actively maintained references for the system.
- **Archive**: older reviews, reports, and diagrams kept for history and traceability.

## Core Documents

### Getting started

- `ARCHITECTURE.md` — current runtime architecture, service boundaries, API surface, and main data flows
- `DATABASE_ERD.md` — active PostgreSQL/Ecto schema and relationship notes
- `TEST_PROCEDURE.md` — practical local validation and smoke-test workflow
- `SYNTAX_GUIDE.md` — business-rule DSL guide for analysts and implementers

### Formal statement

- `MODULE_CAPABILITY_STATEMENT.md` — formal capability statement for procurement/review use

### Validation evidence

- `MANUAL_MOCK_VALIDATION_2026-05-10.md` — recorded mock validation results for the May 10, 2026 verification cycle

## Suggested Reading Order

1. Start with `ARCHITECTURE.md` to understand the system at a high level.
2. Read `DATABASE_ERD.md` to understand the data model.
3. Use `TEST_PROCEDURE.md` for day-to-day validation.
4. Use `SYNTAX_GUIDE.md` when authoring or reviewing business rules.
5. Refer to `MODULE_CAPABILITY_STATEMENT.md` when a formal capability description is needed.

## Archive

Historical analysis and review materials live under `docs/archive/`.
