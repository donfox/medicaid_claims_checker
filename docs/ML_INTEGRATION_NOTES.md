# ML Integration Notes

Working notes for Edition 2's planned Python model-scoring service. They record how the Haskell engine talks to an ML scorer today, and the engine issues to settle before that service is built. They were collected during the October 2026 review of the Haskell engine.

Edition 2's rule applies here as well: an ML score is evidence for an analyst, never a decision.

## Current state

- No Python code exists yet. All ML code is in the Haskell engine: `Claims.MLClient` (the HTTP client), `Claims.PolicyCombiner` (combines rule results with the ML score), and the `/api/evaluate` handler in `haskell_engine/app/Main.hs`.
- **The app does not use ML today.** Phoenix calls only `/api/batch-evaluate`, which runs the rules and never contacts a scorer. Only `/api/evaluate` calls the scorer, and it is used only by direct API calls and tests.
- When `ML_SCORER_URL` is unset, `/api/evaluate` uses a built-in stub result instead of calling a scorer.

### Configuration

| Variable | Meaning | Default |
|---|---|---|
| `ML_SCORER_URL` | Scorer endpoint. Must start with `https://`; private, loopback and metadata hosts are refused. | unset (stub is used) |
| `ML_TIMEOUT_MS` | Response timeout for the scorer call | `120` (ms) |
| `ALLOW_ML_TEST_OVERRIDE` | When `true`, a claim containing `"_mlStatus": "error"` simulates a scorer failure | unset |

### Request the engine sends (`POST` to `ML_SCORER_URL`)

```json
{
  "contract_version": "1.0",
  "request_id": "<claim_id>",
  "claim_id": "<claim_id>",
  "claim": { "source_format": "json", "payload": { "...": "claim JSON with PII removed" } }
}
```

Before sending, the engine removes these fields from the claim JSON:

- the top-level keys `subscriber`, `patient`, `member`, `insured` and `guarantor`;
- `name`, `address`, `city`, `state`, `zip` and `phone` inside `provider`, `billing_provider`, `rendering_provider`, `referring_provider` and `attending_provider`.

### Response the engine accepts

```json
{
  "contract_version": "1.0",
  "status": "ok",
  "model": { "model_id": "fraud_v1", "model_version": "1.0.0" },
  "scores": { "risk_score": 0.42, "confidence": 0.74 },
  "top_factors": [ { "feature": "cpt_mix_divergence", "direction": "up", "contribution": 0.12 } ]
}
```

- `contract_version` must be `"1.0"`.
- `status` is optional and defaults to `"ok"`. Any other value is treated as a scorer error.
- `model.model_id` and `model.model_version` are required.
- `scores.risk_score` is required; `scores.ml_probability` is accepted in its place. Numbers or numeric strings are both accepted.
- `scores.confidence` and `top_factors` are optional. A factor with a missing field gets a default value.

### How the score is used

`PolicyCombiner` compares the risk score with fixed thresholds: 0.35 (low), 0.80 (high) and 0.93 (SIU). A score at or above 0.35 sends the claim to review, and higher bands send it to more senior queues. If the scorer fails, only the rule results are used.

## Issues to resolve before building the Python service

1. **A local Python service is refused.** `validateMlScorerUrl` requires `https://` and blocks any host containing `localhost`, so a development service at `http://localhost:8000` is rejected with only a log warning. It needs a development setting that is clearly separate from production. The same check also wrongly blocks any host starting with `fd` (for example `fd-scorer.example.com`) and does not block the `172.16.0.0/12` private range.
2. **The default timeout is too short.** 120 ms is unlikely to be enough for a Python model service, especially for the first request after it starts.
3. **The stub is not neutral.** It reports `status: "ok"`, risk 0.42 and made-up factors. Because 0.42 is above the 0.35 threshold, every claim is sent to review. It should report a status such as `"disabled"` so that only the rule results are used.
4. **Batch evaluation never calls ML.** That is the only path the app uses. Adding scoring needs a design choice: one scorer call per claim (bounded by the existing worker pool), or a batch endpoint on the Python side.
5. **The contract checks are loose.**
   - The risk score is not checked to be within 0–1.
   - `confidence` is parsed but not used in any decision.
   - The HTTP status code is not checked, so an error response with a JSON body may be accepted.
   - `mlErrorResult` throws away the error message, which makes scorer failures hard to diagnose.
6. **Decisions are worded as outcomes.**
   - A matched `REJECT` rule produces status `REJECT` in queue `"denied"`, which goes against "the system recommends, an analyst decides". `PolicyCombiner` outputs should be reworded as recommendations.
   - `RuleEngine` also computes its own `overallRisk` (any `FLAG_FRAUD` = `CriticalRisk`) separately from `PolicyCombiner`. Settle on a single place where a recommendation is made.
