# ML + DSL Implementation Checklist

This checklist turns the policy contract into executable work items.

Primary reference: `ML_DSL_POLICY_CONTRACT.md`.

## Delivery Model

- Status markers: `[ ]` not started, `[~]` in progress, `[x]` done
- Ownership tags:
  - `[BE]` Haskell backend / API
  - `[FE]` Phoenix frontend / LiveView
  - `[DATA]` Data + model service team
  - `[QA]` Test and release validation

## Phase 0 — Foundations

- [x] `[BE]` Add module for combined decision policy (DSL + ML combiner)
- [x] `[BE]` Define typed DTOs for ML request/response and combined output envelope
- [x] `[BE]` Add policy config loader (thresholds, timeout, fallback, allow_ml_review_on_approve)
- [x] `[BE]` Add strict validation for `contract_version` and required fields
- [ ] `[DATA]` Define first production model identifier and versioning format
- [ ] `[QA]` Approve test fixture set for low/medium/high/siu and ML error paths

## Phase 1 — Backend Contract Wiring

- [x] `[BE]` Add ML scoring client interface (HTTP call abstraction)
- [x] `[BE]` Implement timeout handling (`ml_timeout_ms`) and DSL-only fallback
- [x] `[BE]` Map ML response to normalized internal risk object (`risk_score`, `confidence`, factors)
- [x] `[BE]` Implement deterministic precedence exactly as contract section 3.1
- [x] `[BE]` Emit combined output envelope with `decision`, `dsl`, `ml`, `explanations`, `audit`
- [x] `[BE]` Add reason code generation (`DSL:*`, `ML:*`)

## Phase 2 — Frontend Integration

- [ ] `[FE]` Display ML status (`ok`, `timeout`, `error`) without blocking DSL result rendering
- [ ] `[FE]` Display model metadata (`model_id`, `model_version`) in results panel
- [ ] `[FE]` Display top ML factors as supporting evidence (read-only)
- [ ] `[FE]` Render final queue/status from backend `decision` object
- [ ] `[FE]` Add clear visual marker when decision used DSL-only fallback

## Phase 3 — Audit and Persistence

- [ ] `[BE]` Persist claim evaluation audit record with all required fields from contract section 7
- [ ] `[BE]` Persist correlation fields: `request_id`, `claim_id`, `policy_version`, `contract_version`
- [ ] `[BE]` Persist model governance fields: `model_id`, `model_version`, `trained_at_utc`
- [ ] `[BE]` Add replay utility path to re-evaluate from stored payload + policy version
- [ ] `[QA]` Verify replay determinism for fixed claim + policy + model response fixture

## Phase 4 — Test Coverage

- [x] `[BE]` Unit tests: precedence rules (`REJECT` always wins, ML cannot auto-reject)
- [x] `[BE]` Unit tests: threshold boundaries (`T_low`, `T_high`, `T_siu`) including exact boundary values
- [x] `[BE]` Unit tests: ML timeout/error fallback to DSL-only behavior
- [x] `[BE]` Unit tests: schema validation failures for malformed ML payloads
- [x] `[BE]` Unit tests: schema validation failures for malformed evaluate request payloads
- [ ] `[FE]` UI tests: rendering of ML-present vs ML-missing cases
- [ ] `[QA]` End-to-end tests with representative claim fixtures across all decision branches

## Phase 5 — Rollout Controls

- [ ] `[BE]` Add feature flag: `ml_shadow_mode` (store score, no decision impact)
- [ ] `[BE]` Add feature flag: `ml_queue_influence_enabled`
- [ ] `[BE]` Add per-tenant threshold overrides
- [ ] `[DATA]` Define drift and calibration monitoring outputs for operations dashboard
- [ ] `[QA]` Signoff checklist for enabling queue influence in production

## Decision Table (Implementation Target)

- [ ] `[BE]` Implement this exact routing matrix:

| DSL outcome | ML band | Final status | Queue |
|---|---|---|---|
| REJECT | any | REJECT | denied |
| APPROVE | LOW | APPROVE | none |
| APPROVE | MEDIUM | REQUIRE_REVIEW | manual_review |
| APPROVE | HIGH | REQUIRE_REVIEW | fraud_priority |
| APPROVE | SIU | REQUIRE_REVIEW | siu_escalation |
| APPROVE/REVIEW | ML_ERROR | use DSL-only | policy_default |

## Minimum API Deliverables

- [x] `[BE]` Add endpoint or response extension that returns combined output envelope
- [x] `[BE]` Ensure backward compatibility for current DSL-only consumers
- [ ] `[FE]` Consume new fields without breaking existing report views

## Definition of Done

- [x] Contract section 4 envelope produced in runtime responses
- [x] Contract section 3.1 precedence rules covered by automated tests
- [ ] ML failure path verified in staging with fault injection
- [ ] Audit fields complete and queryable for at least one full batch run
- [ ] Product and compliance signoff recorded
