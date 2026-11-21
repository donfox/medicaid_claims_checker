# ML Plan: trained models before the LLM scorer

Status: **proposal, not started** (written 2026-11-07). Nothing here has been downloaded, built or changed yet. Each phase below ends with a review, and the next one starts only when it is approved.

Edition 2's rule applies throughout: **a model score is evidence for an analyst, never a decision.**
Medicare is not involved at this point
## Why trained models first

The catalogue lists three ML Models, all marked *Not connected* because no scoring service exists. Two of them describe classic machine learning: patterns measured across many providers. A large language model (LLM) can't do that, because it sees one claim at a time and has never seen our data. So the plan is to build trained models first and add the LLM afterwards for the work it suits, which is judging a single claim's coding.

| Catalogue entry | Approach | In this plan |
|---|---|---|
| BillingPatternAnomalyModel | Unsupervised: compare each provider with peers of the same specialty and state | **Phase 2**, the first model |
| ProviderBehaviorRiskModel | Supervised: learn which billing patterns came before a provider's exclusion | **Phase 5** |
| DiagnosisProcedureConsistencyModel | Not a trained model: no public data pairs diagnoses with procedures on real claims together with outcomes | Later: CMS coverage tables as rules, or the LLM |

## Terms used

- **Feature**: one measured fact about a provider, such as services per patient.
- **Peer group**: providers with the same specialty (NPPES taxonomy) in the same state.
- **Label**: a known outcome used to train a supervised model, here "excluded on the LEIE".
- **Model card**: a short report on a model version: its data, its features, its results and its known limits.

## What is already in place

- **The engine's scorer contract** (see [ML_INTEGRATION_NOTES.md](ML_INTEGRATION_NOTES.md)) fits a trained model well. It carries a model ID and version, a 0–1 risk score, a confidence value and top factors (the reasons).
- **The NPPES table** (`nppes_providers`, about 9.9 million providers) provides `taxonomy` (specialty), `state` and `enumeration_date` (the date the NPI was issued, used as provider tenure).
- **Python 3.11 and `uv`** are installed on the development Mac.

## Data

| Source | Contents | Purpose |
|---|---|---|
| HHS *Medicaid Provider Spending* (opendata.hhs.gov), built from T-MSIS, 2018–2024 | For each billing NPI, servicing NPI, procedure (HCPCS) code and month: patients, claims, and the amount Medicaid paid | Billing patterns |
| OIG *List of Excluded Individuals/Entities* (LEIE), oig.hhs.gov | Excluded providers with NPI (where recorded), exclusion type and date | A check for Phase 2; labels for Phase 5 |
| `nppes_providers` (already loaded) | Specialty, state, tenure | Peer groups, tenure feature |

**Limits to keep in mind:**

- The spending data reports only what Medicaid **paid**, not what providers charged, so features compare paid amounts. 2024 is marked preliminary, and quality varies by state.
- One HHS page said the dataset was temporarily unavailable, so Phase 1 starts by checking that it can be downloaded.
- The data covers **real, named providers**. Model output describes an *unusual billing pattern*. It is never worded as fraud, and it is not published outside the development environment.
- LEIE exclusions arrive years late and include non-fraud reasons, such as licensing problems. Older entries often have no NPI.
- The files run to several GB. Each file and its size is confirmed before it is downloaded, and none of them goes into git.

## Storage

Each source is stored where it is used. Phoenix owns every database table, through Ecto migrations, as with `nppes_providers`.

| Data | Size (approx.) | Where | Why |
|---|---|---|---|
| OIG LEIE | ~80,000 rows, ~15 MB | New table `leie_exclusions` | Small, and the app can use it directly: an exclusion check is a standard, deterministic Medicaid rule. It also supplies the Phase 5 labels. OIG updates it monthly. |
| HHS Medicaid Provider Spending (raw) | Several GB (exact size confirmed before download) | Files in `ml/data/`, converted once to Parquet | Only training reads these rows, all at once. DuckDB or Polars does that faster than Postgres, and the app's database stays small. |
| Training results | ~1 million rows, one per provider | New table `ml_provider_scores` (Phase 3) | Features, score, top reasons and model version for each provider: what the scoring service and the claim page read. |

Python reads `nppes_providers` straight from Postgres for peer groups, so nothing is copied.

## Phases

### Phase 1: data in place

- A download script for the HHS Medicaid spending file and the LEIE, saving into `ml/data/`, outside git.
- A script that joins them to `nppes_providers` by NPI and reports coverage: how many billing providers in the spending data match NPPES, and how many LEIE entries have a usable NPI.

**Done when:** you have reviewed the coverage report.

### Phase 2: BillingPatternAnomalyModel

1. **Features**, one row per provider, for example:
   - patients
   - services per patient
   - average paid per service compared with the peer-group median
   - month-to-month change in claims (a sudden jump)
   - share of the highest-level office visits (99205, 99215)
   - number of distinct procedure codes
   - the share billed in the provider's top procedure code
   - tenure
2. **Baseline:** each feature as a percentile within the peer group. This is fully explainable ("99th percentile among family practice providers in Florida").
3. **Model:** an Isolation Forest (scikit-learn), one per peer group, or one with peer-relative features. Its random seed is fixed, so the same data always gives the same model.
4. **Evaluation**, written up in a report:
   - The **top 25 providers** with their top reasons, for your review. Some will turn out legitimate, such as specialty clinics or very sick patient populations. Those findings change the features.
   - **LEIE check:** excluded providers should rank higher than average, even though the model never saw them.
   - **Stability:** train on the earlier year and score the later one; repeat outliers matter most.
   - **Baseline vs model:** keep the Isolation Forest only if it finds something the percentiles miss.
5. **Iterate** on the features: expect a few rounds.
6. **Save version 1:** the model file, its version, the data years used, and a model card.

**Done when:** you accept the model card and the top-25 review.

### Phase 3: scoring service and engine wiring

- **A Python service** (FastAPI) that implements the existing scorer contract. For each claim it looks up the billing provider's precomputed score, adds any claim-level checks, and returns the score with the model ID, version and top factors. Providers not in the spending data are reported as *not assessed*, never as low risk.
- **Engine items** from [ML_INTEGRATION_NOTES.md](ML_INTEGRATION_NOTES.md), fixed first:
  - #1: allow a local development scorer, with a setting clearly separate from production.
  - #2: a realistic timeout.
  - #3: a neutral stub when no scorer is set.
  - #4: call the scorer from the batch path the app actually uses.
  - #9: report a timed-out claim as not assessed, never as clean.
  - #5: stricter contract checks.
- **Calibration:** the engine's bands (0.35 / 0.80 / 0.93) assume probabilities. An anomaly score isn't a probability, so either the service maps it to those bands deliberately, or the bands become per-model settings. This is decided in this phase.
- **Docs:** update ARCHITECTURE (three services) per item #10.

**Done when:** an uploaded batch shows ML results end to end, and all test suites pass.

### Phase 4: show it in the app

- On each claim, the ML finding appears as a recommendation: band, score, top reasons, model version. A claim the model could not assess is shown as such.
- The analyst's decision on a claim is stored with the model version that scored it. These decisions become training labels for future retraining.
- BillingPatternAnomalyModel moves from *Not connected* to *Active* in the catalogue.

**Done when:** you have tried it in the app with mock data.

### Phase 5: ProviderBehaviorRiskModel

- A supervised model (gradient-boosted trees, LightGBM) trained on Phase 2's features plus tenure, with LEIE exclusions as labels.
- Split by time (train on exclusions before a date, test on later ones), so the model is never tested on information it couldn't have had.
- Calibrate it, so a score of 0.8 means roughly an 80% rate among similar providers.
- Evaluate it by **precision in the top-ranked providers**, because analysts can review only so many claims a day. Write a model card, review it, and connect it the same way as in Phase 3.

## Guardrails (all phases)

- **Recommend, never decide.** Model output never rejects a claim.
- **Every score names its model version.** A past score can always be explained by the model as it was then.
- **No automatic learning.** Retraining is a deliberate step, with a new version and a new model card.
- **Same input, same output.** Seeds are fixed and dependency versions pinned.
- **No patient data.** The models use provider-level public data. The engine already strips patient and provider personal fields before calling the scorer.
- **Wording:** "unusual billing pattern", "worth review". Never "fraud" about a named provider.

## Where things live (proposed)

- `ml/`: Python project (managed with `uv`), with download, feature, training and evaluation scripts, the scoring service, and tests.
- `ml/data/` and `ml/models/`: kept out of git (`.gitignore`). Model cards are kept in git under `docs/models/`.

## Decisions needed before Phase 1

1. Is the HHS Medicaid Provider Spending data acceptable as the training data?
2. Is the `ml/` folder layout above acceptable?
3. Is the order acceptable: anomaly model first, supervised model fifth, the LLM afterwards?

## Out of scope

- The full, claim-level T-MSIS files and any data-use agreement.
- The LLM scorer (it follows this plan).
- Automatic retraining.
