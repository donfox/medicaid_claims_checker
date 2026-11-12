# Documentation Guide

## Start here

- [ARCHITECTURE.md](ARCHITECTURE.md): how the Phoenix app and the Haskell engine fit
  together, the engine's API and call structure, and how claims flow through the
  system
- [DATABASE_ERD.md](DATABASE_ERD.md): every database table, its columns and how they
  relate
- [SYNTAX_GUIDE.md](SYNTAX_GUIDE.md): writing business rules in the rule language

## Running and administering

- [CONFIGURATION.md](CONFIGURATION.md): every setting both services read, with its
  default
- [ADMIN_GUIDE.md](ADMIN_GUIDE.md): managing accounts on the Admin page, including
  password links for users without a password or who have forgotten it

## Testing

- [TEST_PROCEDURE.md](TEST_PROCEDURE.md): running the tests and checking a local setup
- [testing/Frontend_Use_Cases.md](testing/Frontend_Use_Cases.md): the 59 things to test
  in the running app, with each one's test files and expected result
- [testing/Repeat_Testing_Guide.md](testing/Repeat_Testing_Guide.md): uploading the same
  test files round after round
- [scripts/](scripts/): SQL queries that audit a batch's provider NPIs against the
  NPPES data, used in `TEST_PROCEDURE.md`

## Planning

- [ML_INTEGRATION_NOTES.md](ML_INTEGRATION_NOTES.md): how the engine talks to an ML
  scorer today, and the open issues for the planned Python scoring service
- [ML_PLAN.md](ML_PLAN.md): the proposed plan for trained ML models (data, training,
  scoring service), ahead of the LLM scorer
## Formal statement

- [MODULE_CAPABILITY_STATEMENT.md](MODULE_CAPABILITY_STATEMENT.md): the capability
  statement EMRTS submitted for review

## Elsewhere in the repository

- [haskell_engine/README.md](../haskell_engine/README.md): the engine's modules,
  building, running and TLS
- [phoenix_web/README.md](../phoenix_web/README.md): where the web app's code is,
  its pages and setup
- [mock_data/README.md](../mock_data/README.md): every test data file, by use case

Older material (earlier reviews, the May 2026 validation report) is in the Git
history and in the `edition-1` tag.
