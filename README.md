# Medicaid Claims Checker

A portfolio prototype for evaluating healthcare claims against configurable business rules and provider data.

## Portfolio Context

I built Medicaid Claims Checker for public portfolio display and technical discussion with interns. Interns were discussion participants only; they did not contribute code and are not co-authors. This is an independent demonstration/proof of concept, not a production claims adjudication or payment system.

Medicaid Claims Checker is one of three independent healthcare-related projects in this portfolio. They explore different parts of the healthcare data space and are not integrated into a shared runtime or end-to-end system:

- [X12Translator](https://github.com/donfox/X12Translator) parses and translates X12 837 claim files.
- **Medicaid Claims Checker** evaluates claims against configurable rules and provider data.
- [Provider Vault](https://github.com/donfox/provider-vault) demonstrates provider-directory features and AI engineering patterns.

## Getting Started

- [Setup instructions](setup.sh)
- [Architecture](docs/ARCHITECTURE.md)
- [Documentation guide](docs/README.md)
- [Business-rule syntax guide](docs/SYNTAX_GUIDE.md)
- [Test procedure](docs/TEST_PROCEDURE.md)

## Scope and Status

This repository is a portfolio demonstration, not evidence of a production deployment or government endorsement. EMRTS submitted its capability statement to state government entities for review; submission does not imply acceptance, endorsement, contract award, integration, or deployment. Deployment, compliance, security, and operational readiness would require separate validation.

See [LICENSE](LICENSE) for the terms that apply to viewing and using this code.