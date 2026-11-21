# Medicaid Claims Checker

A portfolio prototype for evaluating healthcare claims against configurable business rules and provider data.

## Portfolio Context

I built Medicaid Claims Checker for public portfolio display and technical discussion with interns. Interns were discussion participants only; they did not contribute code and are not co-authors. Edition 1 was the teaching version used in those discussions; Edition 2 develops it into a production-ready prototype (see [Editions](#editions)). Neither is a live claims adjudication or payment system.

Medicaid Claims Checker is one of three independent healthcare-related projects in this portfolio. They explore different parts of the healthcare data space and are not integrated into a shared runtime or end-to-end system:

- [X12Translator](https://github.com/donfox/X12Translator) parses and translates X12 837 claim files.
- **Medicaid Claims Checker** evaluates claims against configurable rules and provider data.
- [Provider Vault](https://github.com/donfox/provider-vault) demonstrates provider-directory features and AI engineering patterns.

## Editions

The project has two editions, each a stage in its progression.

- **Edition 1: the teaching edition.** Built as a pedagogical example for discussion with interns: a rule engine and a web interface small enough to read end to end. It is preserved as completed and does not change. In Edition 1, claims the engine rated High or Critical risk, and claims whose provider failed the NPPES check, were labelled fraudulent automatically, a simplification suited to teaching.
- **Edition 2: the production-ready prototype** (the current version, in active development). It takes the same ideas to the standard a real deployment would need: authentication and optional TLS between the web app and the engine, rate limiting, user accounts with administrator roles, duplicate-submission checks, X12 envelope validation, a full NPI registry checked as of each service date, and automated test suites. It is built on one principle: the system recommends and a named analyst decides. Rule results, NPPES checks and optional ML risk scores are evidence for an analyst and never a fraud determination. A planned AI assistant will advise the analyst in the same way (see [Roadmap](#roadmap)). It is still a prototype, run on synthetic data, not a live claims adjudication or payment system.

Each edition is a Git tag; `main` always holds the latest edition. To look at Edition 1:

- [Browse Edition 1's code](https://github.com/donfox/medicaid_claims_checker/tree/edition-1) or [see what has changed since Edition 1](https://github.com/donfox/medicaid_claims_checker/compare/edition-1...main).
- To run it locally, check out the tag, then follow the usual setup:

  ```bash
  git switch --detach edition-1
  scripts/setup.sh
  ```

  Return to the current version with `git switch main` and run `scripts/setup.sh` again.

## Roadmap

Planned for Edition 2:

- **Analyst review workflow:** a case queue, decisions recorded with the analyst, reason and evidence, and supervisor confirmation for serious decisions.
- **Advisory AI assistant:** an API connection to a large language model (LLM) that summarises a claim's findings and drafts review notes for the analyst. Its output will be labelled advisory; it will not be able to change a claim's status or record a decision, and it will be used only with synthetic data.

## Getting Started

You need [Haskell Stack](https://docs.haskellstack.org/), [Elixir](https://elixir-lang.org/install.html) 1.15 or later, and PostgreSQL running locally.

1. `scripts/setup.sh` builds the engine, installs the web app's dependencies, and creates, migrates and seeds the database. It is safe to run again.
2. `scripts/start.sh` starts both services: the web app on port 4000 and the engine on port 8080. Logs go to `logs/`.
3. Open `http://localhost:4000` and log in as the seeded admin, `admin` with password `AdminPassword123!` in development (see [the first admin](docs/ADMIN_GUIDE.md#the-first-admin)).
4. `scripts/test.sh` runs the use-case tests through the app; see [docs/TEST_PROCEDURE.md](docs/TEST_PROCEDURE.md) for the rest.

More on each part:

- [The web app](phoenix_web/README.md): where the code is, and a flowchart of how a batch of claims is processed
- [The rule engine](haskell_engine/README.md): its modules, its API, and a flowchart of how it checks claims
- [Test data](mock_data/README.md): every test file, by use case

## Documentation

How it works:

- [Architecture](docs/ARCHITECTURE.md): how the web app and the rule engine fit together, the engine's API and call structure, and how claims flow through the system
- [Database](docs/DATABASE_ERD.md): every database table, its columns and how they relate
- [Rule syntax](docs/SYNTAX_GUIDE.md): writing business rules in the rule language

Running and administering:

- [Configuration](docs/CONFIGURATION.md): every setting both services read, with its default
- [Admin guide](docs/ADMIN_GUIDE.md): managing accounts on the Admin page, including password links for users without a password or who have forgotten it

Testing:

- [Test procedure](docs/TEST_PROCEDURE.md): running the tests and checking a local setup
- [Frontend use cases](docs/FRONTEND_USE_CASES.md): the 59 things to test in the running app, with each one's test files and expected result, and how to upload the same files round after round

Planning:

- [ML plan](docs/ML_PLAN.md): the proposed plan for the trained ML Models on the Business Rules page (data, training, scoring service), ahead of any LLM step
- [ML integration notes](docs/ML_INTEGRATION_NOTES.md): how the engine talks to an ML scorer today, and the open issues for the planned Python scoring service

Formal statement:

- [Module capability statement](docs/MODULE_CAPABILITY_STATEMENT.md): the capability statement EMRTS submitted for review, kept unchanged as a May 2026 record of Edition 1

Older material (earlier reviews, the May 2026 validation report) is in the Git history and in the `edition-1` tag.

## Scope and Status

This repository is a portfolio demonstration, not evidence of a production deployment or government endorsement. EMRTS submitted its capability statement to state government entities for review; submission does not imply acceptance, endorsement, contract award, integration, or deployment. Deployment, compliance, security, and operational readiness would require separate validation.

See [LICENSE](LICENSE) for the terms that apply to viewing and using this code.