# Medicaid Claims Checker

A portfolio prototype for evaluating healthcare claims against configurable business rules and provider data.

## Portfolio Context

I built Medicaid Claims Checker for public portfolio display and technical discussion with interns. Interns were discussion participants only; they did not contribute code and are not co-authors. This is an independent demonstration/proof of concept, not a production claims adjudication or payment system.

Medicaid Claims Checker is one of three independent healthcare-related projects in this portfolio. They explore different parts of the healthcare data space and are not integrated into a shared runtime or end-to-end system:

- [X12Translator](https://github.com/donfox/X12Translator) parses and translates X12 837 claim files.
- **Medicaid Claims Checker** evaluates claims against configurable rules and provider data.
- [Provider Vault](https://github.com/donfox/provider-vault) demonstrates provider-directory features and AI engineering patterns.

## Editions

- **Edition 2** (the current version, in active development) is built on one principle: the system recommends and a named analyst decides. Rule results, NPPES checks and optional ML risk scores are evidence for an analyst and never a fraud determination. A planned AI assistant will advise the analyst in the same way (see [Roadmap](#roadmap)).
- **Edition 1** is preserved as completed: [Edition 1 release](https://github.com/donfox/medicaid_claims_checker/releases/tag/edition-1). In Edition 1, claims the engine rated High or Critical risk, and claims whose provider failed the NPPES check, were labelled fraudulent automatically.

Each edition is a Git tag; `main` always holds the latest edition. To look at Edition 1:

- [Browse Edition 1's code](https://github.com/donfox/medicaid_claims_checker/tree/edition-1) or [see what has changed since Edition 1](https://github.com/donfox/medicaid_claims_checker/compare/edition-1...main).
- To run it locally, check out the tag, then follow the usual setup:

  ```bash
  git switch --detach edition-1
  ./setup.sh
  ```

  Return to the current version with `git switch main` and run `./setup.sh` again.

## Roadmap

Planned for Edition 2:

- **Analyst review workflow:** a case queue, decisions recorded with the analyst, reason and evidence, and supervisor confirmation for serious decisions.
- **Advisory AI assistant:** an API connection to a large language model (LLM) that summarises a claim's findings and drafts review notes for the analyst. Its output will be labelled advisory; it will not be able to change a claim's status or record a decision, and it will be used only with synthetic data.

## Getting Started

- [Setup instructions](setup.sh)
- [Where the Phoenix code is](phoenix_web/README.md#where-the-code-is) — the web app's folders explained
- [Test data](mock_data/README.md) — every test file, by use case
- [Architecture](docs/ARCHITECTURE.md)
- [Documentation guide](docs/README.md)
- [Business-rule syntax guide](docs/SYNTAX_GUIDE.md)
- [Test procedure](docs/TEST_PROCEDURE.md)

## Scope and Status

This repository is a portfolio demonstration, not evidence of a production deployment or government endorsement. EMRTS submitted its capability statement to state government entities for review; submission does not imply acceptance, endorsement, contract award, integration, or deployment. Deployment, compliance, security, and operational readiness would require separate validation.

See [LICENSE](LICENSE) for the terms that apply to viewing and using this code.