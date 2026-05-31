# Module Capability Statement
## Claims Integrity and Fraud Detection Module

**Version:** 1.0  
**Date:** May 2026  
**Status:** Draft — for HCPF procurement review

---

## 1. Module Purpose

The Claims Integrity and Fraud Detection Module receives X12 837P, 837I, and 837D claim transactions, evaluates them against configurable business rules and the national NPPES provider registry, and produces fraud risk findings to support pre-adjudication decision-making.

This module is a **pre-adjudication tool**. It does not adjudicate claims, make payment decisions, or determine member eligibility. Its purpose is to flag potentially fraudulent, erroneous, or high-risk claims before they proceed through the adjudication process.

---

## 2. Capability Boundary

### 2.1 What This Module Does

- Ingests X12 837P (Professional), 837I (Institutional), and 837D (Dental) claim transactions
- Translates X12 EDI to structured JSON for rule evaluation
- Validates provider National Provider Identifiers (NPIs) against the CMS NPPES provider registry
- Hard-rejects claims with unrecognised or deactivated provider NPIs prior to rule evaluation
- Evaluates claims against a configurable library of business rules authored in a domain-specific language (DSL)
- Supports three rule types: Default Rules (system-defined), BA Rules (business-analyst-authored), and ML Model scoring
- Detects redundant or conflicting rules in the rule library before activation
- Produces per-claim risk findings: CriticalRisk, HighRisk, MediumRisk, LowRisk
- Produces per-claim weighted fraud scores based on the severity of triggered rules
- Stores evaluation history and per-claim audit trail in a PostgreSQL database
- Accepts claim files via SFTP, HTTP, local directory, or Databricks on configurable cron or interval schedules
- Provides a web-based UI for rule management, manual file upload, batch monitoring, and findings review

### 2.2 What This Module Does NOT Do

- Does not adjudicate claims
- Does not make payment decisions
- Does not generate X12 835 remittance advice
- Does not determine member eligibility
- Does not manage provider enrollment
- Does not interface directly with beneficiaries
- Does not replace the MMIS — it supplements it with pre-adjudication fraud findings

---

## 3. Inputs and Outputs

| Direction | Description | Format |
|---|---|---|
| **In** | X12 837P Professional claims | X12 EDI |
| **In** | X12 837I Institutional claims | X12 EDI |
| **In** | X12 837D Dental claims | X12 EDI |
| **In** | NPPES National Provider Registry | CMS bulk download (CSV) |
| **Out** | Per-claim fraud/integrity findings | JSON (database + UI) |
| **Out** | Batch evaluation summary | UI display + database |
| **Out** | Evaluation audit trail | PostgreSQL |

---

## 4. Risk Scoring Model

Each evaluated claim receives an overall risk classification based on the actions triggered by matched rules:

| Risk Level | Condition |
|---|---|
| **CriticalRisk** | Any rule triggers RejectClaim or FlagFraud, or NPI validation fails |
| **HighRisk** | 3 or more rules trigger risk scores ≥ 70 |
| **MediumRisk** | 1–2 rules trigger risk scores ≥ 70 |
| **LowRisk** | No high-severity rule actions triggered |

A weighted score is also computed per claim based on the severity of each triggered rule action (Reject = 3 pts, FlagFraud = 2 pts, RequireReview = 1 pt).

---

## 5. NPPES Provider Validation

The module maintains a local copy of the CMS NPPES provider registry, refreshed automatically on a configurable schedule (default: weekly). Prior to rule evaluation, each claim's provider and billing NPIs are validated:

- NPI not found in registry → hard reject, CriticalRisk
- NPI deactivated before service date → hard reject, CriticalRisk
- NPI valid and active → claim proceeds to rule evaluation

---

## 6. Business Rule Library

Rules are authored in a plain-English domain-specific language (DSL) designed for business analysts without programming expertise. The rule library supports:

- Field comparisons (`claim_amount > 50000`)
- Logical operators (`AND`, `OR`, `NOT`)
- Quantifiers over service lines (`EXISTS`, `FORALL`, `COUNT`)
- Procedure and diagnosis code checks
- Provider status checks
- Composite actions (flag + score + require review in a single rule)

The UI provides real-time syntax validation and redundancy detection — rules that conflict with or duplicate existing rules are flagged before activation.

---

## 7. Claim Ingestion Sources

| Source Type | Description |
|---|---|
| SFTP | Scheduled pull from SFTP server |
| HTTP | Scheduled pull from HTTP/HTTPS endpoint |
| Databricks | Scheduled pull from Databricks file store |
| Local Directory | File system path (on-premise deployments) |
| Manual Upload | Browser-based upload via UI (`.x12`, `.edi`, `.json`, `.zip`) |

Each source supports independent cron-expression or interval-based scheduling, with per-source enable/disable controls.

---

## 8. CMES Integration

This module is designed to operate as a named capability within the Colorado Medicaid Enterprise Solutions (CMES) ecosystem. Specific integration protocols — including how claim batches are delivered from the MMIS module and how findings are returned — are subject to HCPF interface specifications provided during the procurement process.

The module exposes the following API endpoints for integration:

| Endpoint | Method | Purpose |
|---|---|---|
| `GET /api/health` | GET | Liveness check |
| `GET /api/fetch-config` | GET | Return active fetch source configuration |

Additional integration endpoints (batch submission, findings retrieval) will be designed to HCPF specifications.

---

## 9. Technology Stack

| Component | Technology |
|---|---|
| Web application | Elixir / Phoenix LiveView |
| Rule evaluation engine | Haskell (deterministic DSL evaluator) |
| Database | PostgreSQL |
| Job processing | Oban (Postgres-backed job queue) |
| Scheduling | Quantum (cron-based scheduler) |
| Deployment | Standalone service, configurable port |

---

## 10. Throughput Characteristics

| Scenario | Estimate |
|---|---|
| Light rules (simple comparisons) | ~120 claims/sec |
| Heavy rules (nested quantifiers) | ~30 claims/sec |
| 10,000-claim batch | 1–8 minutes depending on rule complexity |

Batch chunk size and concurrency are configurable. The architecture supports horizontal scaling of the Phoenix layer.

---

## 11. License

Proprietary — All rights reserved.  
No permission is granted to use, copy, modify, or distribute this software without prior written consent from the copyright owner.
