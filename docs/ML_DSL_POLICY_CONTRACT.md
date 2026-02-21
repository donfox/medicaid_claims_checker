# ML + DSL Policy Contract

This document defines a concrete integration contract between:

- The deterministic DSL rule engine (source of truth for hard policy)
- The probabilistic ML scoring service (risk prioritization)

The goal is to preserve explainability and compliance while adding adaptive risk ranking.

Implementation tracking: `ML_DSL_IMPLEMENTATION_CHECKLIST.md`.

## 1) Scope and Non-Goals

### In scope

- Request/response schema between rule engine and ML scorer
- Deterministic decision precedence
- Threshold policy and action routing
- Audit record requirements

### Non-goals

- ML training pipeline details
- Feature engineering internals
- UI layout details

## 2) Contract: Inputs and Outputs

### 2.1 ML Scoring Request

The rule engine (or orchestration layer) sends this payload to the ML service.

```json
{
  "contract_version": "1.0",
  "request_id": "req_2026_02_20_001",
  "claim_id": "claim_12345",
  "tenant_id": "payer_a",
  "event_time_utc": "2026-02-20T18:31:24Z",
  "claim": {
    "source_format": "json",
    "payload": {
      "2300": { "CLM": { "02": 1845.22 } },
      "2400": []
    }
  },
  "context": {
    "provider_id": "npi_1111111111",
    "member_id_hash": "sha256:...",
    "line_of_business": "commercial",
    "region": "TX"
  }
}
```

### 2.2 ML Scoring Response

```json
{
  "contract_version": "1.0",
  "request_id": "req_2026_02_20_001",
  "model": {
    "model_id": "fraud_gbm_v7",
    "model_version": "7.3.1",
    "trained_at_utc": "2026-02-10T03:15:00Z"
  },
  "scores": {
    "risk_score": 0.83,
    "confidence": 0.77,
    "calibrated": true
  },
  "top_factors": [
    {
      "feature": "provider_30d_outlier_rate",
      "direction": "up",
      "contribution": 0.21
    },
    {
      "feature": "cpt_mix_divergence",
      "direction": "up",
      "contribution": 0.13
    }
  ],
  "status": "ok",
  "latency_ms": 41
}
```

## 3) Decision Contract (Deterministic Precedence)

All final decisions are deterministic and auditable.

1. Evaluate DSL rules first.
2. Read ML score (if available).
3. Apply precedence below in order.

### 3.1 Precedence Rules

1. **Hard deny/reject from DSL wins always**
   - If any DSL action is `REJECT`, final decision is `REJECT`.
2. **Hard allow from DSL can still be reviewed by ML only if policy permits**
   - If DSL says approve and policy flag `allow_ml_review_on_approve = true`, ML may route to review queue.
   - ML must not convert an approve into reject directly.
3. **ML only influences routing priority, not compliance constraints**
   - ML can escalate to review/SIU queue.
   - ML cannot bypass required DSL rejection conditions.
4. **Fail-safe behavior**
   - If ML is unavailable or times out, process with DSL-only path.

### 3.2 Reference Thresholds

Default thresholds (tunable per tenant):

- `T_low = 0.35`
- `T_high = 0.80`
- `T_siu = 0.93`

Routing logic:

- `risk_score < T_low` and no DSL concerns -> auto-approve
- `T_low <= risk_score < T_high` -> manual review queue
- `T_high <= risk_score < T_siu` -> priority fraud review queue
- `risk_score >= T_siu` -> SIU escalation queue (still not auto-reject unless DSL says reject)

## 4) Engine Output Envelope

The Haskell service should return a normalized combined output.

```json
{
  "claim_id": "claim_12345",
  "decision": {
    "status": "REQUIRE_REVIEW",
    "reason_codes": [
      "DSL:missing_auth",
      "ML:risk_ge_0_80"
    ],
    "queue": "fraud_priority"
  },
  "dsl": {
    "matched_rules": ["missing_auth", "high_amount"],
    "actions": [
      { "type": "REQUIRE_REVIEW", "message": "Prior auth missing" },
      { "type": "RISK_SCORE", "value": 70 }
    ]
  },
  "ml": {
    "status": "ok",
    "risk_score": 0.83,
    "confidence": 0.77,
    "model_id": "fraud_gbm_v7",
    "model_version": "7.3.1"
  },
  "explanations": {
    "dsl": [
      "Rule missing_auth matched because 2300.REF.G1 is null"
    ],
    "ml_top_factors": [
      "provider_30d_outlier_rate",
      "cpt_mix_divergence"
    ]
  },
  "audit": {
    "policy_version": "policy_2026_02",
    "contract_version": "1.0",
    "evaluated_at_utc": "2026-02-20T18:31:25Z"
  }
}
```

## 5) Policy Config (Tenant-Tunable)

Example policy document:

```json
{
  "policy_version": "policy_2026_02",
  "allow_ml_review_on_approve": true,
  "thresholds": {
    "low": 0.35,
    "high": 0.80,
    "siu": 0.93
  },
  "timeouts": {
    "ml_timeout_ms": 120
  },
  "fallback": {
    "on_ml_error": "dsl_only"
  }
}
```

## 6) Minimal State Machine

- `DSL_REJECT` -> `FINAL_REJECT`
- `DSL_APPROVE + ML_LOW` -> `FINAL_APPROVE`
- `DSL_APPROVE + ML_MEDIUM` -> `FINAL_REVIEW`
- `DSL_APPROVE + ML_HIGH` -> `FINAL_FRAUD_PRIORITY`
- `DSL_APPROVE + ML_SIU` -> `FINAL_SIU_QUEUE`
- `ML_ERROR` -> evaluate via DSL-only policy

## 7) Audit and Compliance Requirements

For each evaluated claim, persist:

- Raw claim hash and claim ID
- Matched DSL rules and emitted DSL actions
- ML model ID/version, score, confidence, and top factors
- Final decision and queue assignment
- Policy version and contract version
- Evaluation timestamp and request correlation ID

This supports replay, regulator audits, and model governance.

## 8) Rollout Plan (Recommended)

1. **Shadow mode**: Store ML outputs, do not affect routing.
2. **Queue-only influence**: ML affects review priority only.
3. **Threshold tuning**: Calibrate by precision/recall and workload.
4. **Continuous monitoring**: Drift, calibration, and subgroup performance.

## 9) Acceptance Criteria

The integration is complete when all are true:

- Combined output envelope matches Section 4 exactly.
- Precedence rules in Section 3.1 are enforced in tests.
- ML timeout/error path reliably falls back to DSL-only decisions.
- Every decision record contains required audit fields.

## 10) `/api/evaluate` Request Contract (Current Engine)

The backend now enforces a strict request contract for `/api/evaluate`.

Required fields:

- `contract_version` (must be `"1.0"`)
- `request_id` (non-empty string)
- `claim_id` (non-empty string)
- `tenant_id` (non-empty string)
- `rulesText` (DSL rule text)
- `document` (claim JSON object/value)

Optional fields:

- `context` (object)

### Valid example

```json
{
  "contract_version": "1.0",
  "request_id": "req_2026_02_20_123",
  "claim_id": "claim_12345",
  "tenant_id": "payer_a",
  "rulesText": "RULE r1 \"Check\" WHEN 2300.CLM.02 > 1000 THEN REQUIRE_REVIEW \"high\";",
  "document": {
    "2300": { "CLM": { "02": 1845.22 } }
  },
  "context": {
    "line_of_business": "commercial",
    "region": "TX"
  }
}
```

### Invalid examples (rejected with 400)

Unsupported version:

```json
{
  "contract_version": "2.0",
  "request_id": "req_1",
  "claim_id": "claim_1",
  "tenant_id": "payer_a",
  "rulesText": "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
  "document": {}
}
```

Missing correlation ID:

```json
{
  "contract_version": "1.0",
  "claim_id": "claim_1",
  "tenant_id": "payer_a",
  "rulesText": "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
  "document": {}
}
```

Empty tenant:

```json
{
  "contract_version": "1.0",
  "request_id": "req_1",
  "claim_id": "claim_1",
  "tenant_id": "   ",
  "rulesText": "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
  "document": {}
}
```

### Compatibility note

Older clients that sent only `rulesText` + `document` must now include the required contract and correlation fields.

## 11) Client Migration Checklist

Use this checklist when updating Phoenix UI or external API callers.

- [ ] Add request fields to `/api/evaluate` payload:
  - `contract_version: "1.0"`
  - `request_id` (unique per call)
  - `claim_id` (stable claim identifier)
  - `tenant_id` (non-empty tenant/payer key)
- [ ] Keep existing fields:
  - `rulesText`
  - `document`
- [ ] Optionally include `context` object when available.
- [ ] On HTTP 400, surface backend `error` message directly in client logs/UI.
- [ ] Add client-side validation for empty `request_id`, `claim_id`, `tenant_id`.
- [ ] Add contract-version constant in caller code to avoid drift.
- [ ] Add a smoke test with one valid and one invalid payload.

### Suggested rollout

1. **Dual-path prep**: update caller payload builder in dev/staging.
2. **Validation**: confirm 200 on valid payload, 400 on malformed payload.
3. **Release**: deploy caller updates before enforcing stricter server-side behavior in other endpoints.
4. **Monitoring**: track 400 rate for `/api/evaluate` for 24-48 hours after deploy.

## 12) Phoenix Request Builder Snippet

Use this pattern in Phoenix when calling `POST /api/evaluate`.

```elixir
def build_evaluate_payload(rules_text, claim_document, opts \\ %{}) do
  %{
    "contract_version" => "1.0",
    "request_id" => Map.get(opts, :request_id, "req_" <> Integer.to_string(System.system_time(:millisecond))),
    "claim_id" => Map.get(opts, :claim_id, "claim_unknown"),
    "tenant_id" => Map.get(opts, :tenant_id, "default_tenant"),
    "rulesText" => rules_text,
    "document" => claim_document,
    "context" => Map.get(opts, :context, %{})
  }
end

def call_evaluate_api(payload) do
  url = "http://localhost:8080/api/evaluate"
  headers = [{"content-type", "application/json"}]
  body = Jason.encode!(payload)

  case HTTPoison.post(url, body, headers, recv_timeout: 30_000) do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
      {:ok, Jason.decode!(body)}

    {:ok, %HTTPoison.Response{status_code: 400, body: body}} ->
      # Backend returns {"error": "..."}; surface this message directly
      {:error, Jason.decode!(body)}

    {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
      {:error, %{"error" => "Unexpected status #{code}", "raw" => body}}

    {:error, reason} ->
      {:error, %{"error" => "HTTP request failed", "reason" => inspect(reason)}}
  end
end
```

### Placement Guidance

- Build payload in the same module where the evaluate action is triggered (for example, your LiveView event handler).
- Keep `contract_version` as a single constant in one place.
- Always log `request_id` and `claim_id` with failures to simplify tracing.
