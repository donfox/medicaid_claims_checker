# ML Import Plan from X12 Claims Processing POC

This document maps reusable ML assets from sibling repo `../X12_claims_processing_poc` into `JSON_claims_integrity`.

Use this with:

- `ML_DSL_POLICY_CONTRACT.md`
- `ML_DSL_IMPLEMENTATION_CHECKLIST.md`

## 1) Objective

Adopt proven patterns from the Python POC while preserving this project's core design:

- DSL remains deterministic source of truth
- ML augments risk ranking and queue routing
- Final decision precedence remains policy-driven and auditable

## 2) Source Assets Identified

From `../X12_claims_processing_poc`:

- Feature extraction pipeline:
  - `fraud_api/feature_extractor.py`
- Trained-model workflow and artifact shape:
  - `fraud_api/ml_trainer.py`
  - `fraud_api/models/fraud_model.pkl`
- Runtime scoring integration:
  - `fraud_api/api_service.py`
- Rule+ML hybrid orchestration precedent:
  - `docs/ARCHITECTURE.md`

## 3) What to Reuse vs Rebuild

### Reuse (concepts/contracts)

- Feature schema patterns (claim amounts, service-line stats, procedure diversity, age, timing)
- ML response fields (`risk_score`/probability, model metadata, top factors)
- API-level fallback behavior when model is unavailable

### Rebuild (implementation)

- Do not import Python weighted-scoring model directly into Haskell engine runtime.
- Do not copy hard-coded hybrid weighting (60/40); use tenant policy config from `ML_DSL_POLICY_CONTRACT.md`.
- Do not carry filename-based fraud heuristics into production rules.

## 4) File-Level Mapping (Source → Target)

| Source (POC) | Purpose | Target in this repo | Action |
|---|---|---|---|
| `fraud_api/feature_extractor.py` | Feature definitions and extraction logic | New feature contract doc under `docs/` + optional sidecar service | Extract feature dictionary spec; implement as separate scorer service (Python) or service call contract |
| `fraud_api/ml_trainer.py` | Training + model serialization pattern | `docs/` + external ML pipeline | Reuse methodology and feature naming; train model outside Haskell engine |
| `fraud_api/models/fraud_model.pkl` | Serialized model artifact format | External model registry/artifacts | Replace with versioned model artifacts managed by ML pipeline |
| `fraud_api/api_service.py` | Inference API and hybrid assembly | `haskell_engine/app/Main.hs` + new combiner module | Implement ML client + deterministic policy combiner in Haskell |
| `docs/ARCHITECTURE.md` | Integration topology | `docs/ARCHITECTURE.md` (this repo) | Add architecture extension section for ML sidecar + policy combiner |

## 5) Recommended Target Architecture

1. Keep DSL evaluation inside Haskell (`RuleEngine`).
2. Add `MLClient` abstraction in Haskell backend for HTTP scoring call.
3. Add `PolicyCombiner` module implementing precedence from `ML_DSL_POLICY_CONTRACT.md`.
4. Return combined output envelope (`decision`, `dsl`, `ml`, `audit`) from API.
5. Phoenix displays combined decision and ML explanation fields without changing DSL editing UX.

## 6) Proposed Implementation Slices

### Slice A — Contract-Only Integration (No Real Model)

- Add typed request/response DTOs for ML payloads.
- Add stub ML adapter returning deterministic fixture response.
- Implement precedence combiner + tests.

Exit criteria:

- Combined output envelope produced in `/api/evaluate` path.
- ML timeout/error fallback tested and stable.

### Slice B — Sidecar Scorer Integration

- Stand up Python scorer service (may start from POC `api_service.py` behavior).
- Replace stub with real HTTP call and timeout handling.
- Include model metadata in responses (`model_id`, `model_version`, `trained_at_utc`).

Exit criteria:

- End-to-end scoring path works in dev with sidecar service.
- Queue routing changes only for non-reject DSL outcomes.

### Slice C — Production Hardening

- Add policy/threshold per tenant.
- Add audit persistence for every decision.
- Add drift/calibration observability hooks.

Exit criteria:

- Replayable decisions with policy + model versions.
- Compliance/audit fields complete.

## 7) Interface Definition to Implement First

### Haskell → ML scorer request

- `contract_version`
- `request_id`
- `claim_id`
- `tenant_id`
- `event_time_utc`
- `claim.payload` (raw JSON claim)
- `context` (provider/member/LOB/region where available)

### ML scorer → Haskell response

- `status` (`ok`/`error`)
- `model.model_id`
- `model.model_version`
- `model.trained_at_utc`
- `scores.risk_score`
- `scores.confidence`
- `top_factors[]`
- `latency_ms`

## 8) Risks and Mitigations

- **Risk:** POC metrics are from small labeled dataset.
  - **Mitigation:** treat as bootstrap only; retrain on larger representative data.
- **Risk:** Feature drift between extractor and live payloads.
  - **Mitigation:** version feature schema and reject unknown contract versions.
- **Risk:** ML decision overreach.
  - **Mitigation:** enforce DSL-first precedence in tests; ML cannot auto-reject.

## 9) Immediate Next Engineering Task

Implement Slice A now:

1. Add `PolicyCombiner` module in `haskell_engine/src/X12/DSL/`.
2. Add ML DTO types and stub adapter.
3. Add table-driven precedence tests in `haskell_engine/test/Spec.hs`.
4. Extend evaluate response to include combined envelope fields.
