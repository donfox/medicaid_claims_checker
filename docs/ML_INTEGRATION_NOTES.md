# ML Integration Notes

Working notes for Edition 2's planned Python scoring service, which will first serve the trained ML Models in [ML_PLAN.md](ML_PLAN.md). They record how the Haskell engine talks to an ML scorer today, and the engine issues to settle before that service is built. They were collected during the October 2026 review of the Haskell engine.

Edition 2's rule applies here as well: an ML score is evidence for a business analyst (BA), never a decision.

## Current state

- No Python code exists yet. All ML code is in the Haskell engine: `Claims.MLClient` (the HTTP client, its result types and its settings), `Claims.PolicyCombiner` (combines rule results with the ML score), and `Claims.Pipeline` (when the scorer is called, and the stub and fallback results), which the `/api/evaluate` handler in `haskell_engine/app/Routes.hs` calls.
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

## Which scorer comes first

The first scorer will serve the **trained ML Models** in [ML_PLAN.md](ML_PLAN.md): fixed, versioned functions built here from public provider data. The current contract was designed for that kind of model (a model ID and version, a 0–1 score and top factors), so it fits them well. One point still applies: an anomaly score is not a probability, so it has to be mapped to the bands deliberately (ML_PLAN.md, Phase 3).

Calling an outside LLM through an API is a **separate, later step**. It also depends on the decision to avoid commercial services for now. When it comes, the contract raises three points:

- **Scores are not calibrated.** An LLM can return a number, but it is not a probability, and the same claim can score differently from run to run. The fixed bands (0.35 / 0.80 / 0.93) assume a calibrated score.
- **The useful output is the explanation.** The contract has no free-text field, only `top_factors`. Under Edition 2 the LLM's reasons are the evidence a BA needs, so the contract probably needs a rationale field.
- **Categories may fit better than a score.** For example *no concern / worth a look / needs review*. `MediumRisk` is not produced by the rules (see item 6) and is reserved: "worth a look" is a natural candidate for it.

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
   - A matched `REJECT` rule produces status `REJECT` in queue `"denied"`, which goes against "the system recommends, a BA decides". `PolicyCombiner` outputs should be reworded as recommendations.
   - `Evaluator` also computes its own `overallRisk` (any `FLAG_FRAUD` = `CriticalRisk`) separately from `PolicyCombiner`. Settle on a single place where a recommendation is made.
   - `overallRisk` is what Phoenix uses to flag claims for review today. Since the October 2026 review, a matched `REQUIRE_REVIEW` or a risk score ≥ 70 gives `HighRisk` (before, these stayed Low or Medium and were not flagged), and `MediumRisk` is no longer produced. When ML scores join the decision, an ML band should be able to raise a claim to flagged in the same way.
7. **Missing data.** Each rule result now has `resultUndecided` (the rule could not be checked because of missing or unusable data) and the report has `undecidedRules`. The app shows these rules as not checked. The LLM scorer will face the same question: decide whether it is told which rules could not be checked, and how it reports a claim it cannot assess because data is missing (it should not look like a low score). Each undecided result's `resultDetails` now names the missing or unusable fields, so the scorer request could pass that list along.
8. **The evaluate endpoint and request contract.**
   - `/api/evaluate` does not apply the 512 KB `rulesText` limit that `/api/batch-evaluate` applies.
   - `request_id` and `tenant_id` are required and checked for blanks, then dropped. The scorer request uses `claim_id` as its `request_id`, so the caller's correlation ID never reaches the Python service.
   - Since 2026-11-17 (8fe4a1e), a timeout on `/api/evaluate` is answered with 503 and `"reason": "timeout"` instead of 400. `contract_version` and `context` are also required and never used.
   - Since 2026-11-18 (1fab3ef), Phoenix sends `/api/batch-evaluate` only `rulesText` and `claims`. When the app starts calling the scorer path, the contract fields (`contract_version`, `request_id`, `claim_id`, `tenant_id`, `context`) have to be built again; the old builder is in git before 1fab3ef.
   - **Fixed 2026-11-25:** `ML_SCORER_URL`, `ML_TIMEOUT_MS` and `ALLOW_ML_TEST_OVERRIDE` are read once at startup (`Claims.Pipeline.loadEngineConfig`) and passed to each request, so changing them needs an engine restart. A rejected URL is logged once, and the startup output says whether the scorer is on.
9. **Fixed 2026-11-17 (33e2ccb):** a timed-out claim now carries `"reason": "timeout"` and Phoenix stores it as *not assessed*, never clean. Keep this when scorer calls join the batch path: a scorer timeout is *not assessed*, never a low score. The original note follows.

   **A timed-out claim would look like a clean claim.** When a claim exceeds the 30 s per-claim limit, `/api/batch-evaluate` returns `{"claimIndex": i, "error": ...}` with no `report`. Phoenix reads the missing report as an empty one and stores the file as evaluated, which displays as `LowRisk` with no rules matched or not checked. No claim is known to have come near 30 s, so this is not fixed. A per-claim scorer call in the batch path would make timeouts more likely; if that is added, fix this first, and report a scorer timeout as not assessed, never as a low score.
10. **Update the architecture wording.** The docs describe the system as two services and never use "polyglot" or "microservices" (checked 2026-11-06). When the Python service is added, revise the System Summary in `docs/ARCHITECTURE.md` (and the README if it describes the layout): three services in three languages, with the Python service called by the engine through `ML_SCORER_URL`, not by Phoenix. Decide then whether to call the design "microservices"; "polyglot" fits either way.
