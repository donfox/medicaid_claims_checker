# ML Plan: trained models before the LLM scorer

Status: **proposal, not started** (written 2026-11-07). Nothing here has been downloaded, built or changed yet. Each phase below ends with a review, and the next one starts only when it is approved.

Edition 2's rule applies throughout: **a model score is evidence for an analyst, never a decision.**
Medicare is not involved at this point
## Why trained models first

The catalogue lists ten ML Models (see [The ML Models](#the-ml-models) below), all marked *Not connected* because no scoring service exists. They describe classic machine learning: functions whose limits and weights are learned from data, then frozen and versioned. A large language model (LLM) can't do that, because it sees one claim at a time and has never seen our data. So the plan is to build trained models first and add the LLM afterwards for the work it suits, which is judging a single claim's coding.

| Catalogue entry | Approach | In this plan |
|---|---|---|
| BillingPatternAnomalyModel | Unsupervised: compare each provider with peers of the same specialty and state | **Phase 2**, the first model |
| ProviderBehaviorRiskModel | Supervised: learn which billing patterns came before a provider's exclusion | **Phase 5** |
| DiagnosisProcedureConsistencyModel | Association statistics on the claims this app has checked: no public data pairs diagnoses with procedures | Later, once real claims accumulate. CMS coverage tables become a Default Rule instead. |

## The ML Models

Ten ML Models make a fairly complete set (agreed 2026-11-20). Checks that follow fixed published tables or simple thresholds are Default Rules instead (see [Default Rule candidates](#default-rule-candidates)). Several smaller ideas are merged into one model as its features.

**Data:** *Public* = HHS spending, LEIE and NPPES, available now. *Claims* = claims this app has checked, once enough real ones accumulate. *Decisions* = analyst decisions stored in the app.

| # | ML Model | ML technique | Data | Covers |
|---|---|---|---|---|
| 1 | BillingPatternAnomalyModel | Unsupervised anomaly detection (Isolation Forest) | Public | Unusual on many measures at once; procedure mix, code concentration and payment outliers are its features |
| 2 | UpcodingModel | Peer-distribution comparison | Public | Share of the highest office and emergency-room visit (E/M) levels, e.g. 99205/99215 and 99285 |
| 3 | BillingSurgeModel | Time series, change-point detection | Public | Sudden jumps, new providers billing heavily soon after enrolling ("bust-out"), forecast vs. actual |
| 4 | ProviderBehaviorRiskModel | Supervised classification (gradient-boosted trees) | Public, LEIE as labels | Patterns that came before an exclusion |
| 5 | ProviderNetworkModel | Graph analysis | Public | Billing and servicing links, shared addresses or officials, closeness to excluded providers |
| 6 | ClaimAmountAnomalyModel | Unsupervised, claim level | Claims | A claim far from similar claims (procedure, specialty, state) |
| 7 | DiagnosisProcedureConsistencyModel | Association statistics | Claims | Diagnosis and procedure pairs that rarely occur together |
| 8 | ModifierUsageModel | Peer-distribution comparison | Claims | Use of modifiers such as 25 and 59 compared with peers |
| 9 | AnalystOutcomeModel | Supervised, learns from feedback | Claims, Decisions | Which flagged claims analysts usually confirm; orders the review queue |
| 10 | RuleEffectivenessModel | Supervised, threshold tuning | Claims, Decisions | Which Default and BA Rules lead to confirmed findings; suggests better limits |

**Build order:** models 1–5 use public data and can be built first (1 in Phase 2, 4 in Phase 5; 2, 3 and 5 follow the same steps as Phase 2). Models 6–8 wait for real claims, and 9–10 for enough analyst decisions.

**Possible only with a decision to use patient data (PHI):** SharedPatientNetworkModel (providers with unusual patient overlap) and MemberUtilizationModel (a member's use far above members with similar diagnoses). They are not in the catalogue.

**Related rules, not duplicates:** `HighComplexityERVisit` (UpcodingModel), `NewProviderLargeSubmission` (BillingSurgeModel) and `ExcessiveTotalCharges` / `HighValueClaim` / `SuspiciouslyLowCharge` (ClaimAmountAnomalyModel) use a fixed limit someone chose; the ML Model learns its limit per peer group. Both are kept.

### Default Rule candidates

These came up as ML ideas but follow fixed published tables or simple thresholds, so they need no training. Since 2026-11-20 they are in the catalogue as Default Rules with status *Not connected*: listed, never run, until their data is loaded and their logic written. Near-duplicates widened `DuplicateClaims` instead of adding a rule. The last three rows were added the same day, from a review of what the rules and models together would miss (see [Limits of the whole system](#limits-of-the-whole-system)).

| Check | As a Default Rule | Catalogue entry |
|---|---|---|
| Units of service | CMS MUE limits per procedure code | `UnitsOfServiceLimit` |
| Unbundling | CMS NCCI code-pair edits | `UnbundledProcedurePair` |
| Place of service | CMS place-of-service validity per code | `PlaceOfServiceMismatch` |
| Near-duplicate claims | Same provider, member, date and code, with a different amount | `DuplicateClaims` (widened) |
| Excluded provider | Billing or servicing NPI on the LEIE table | `ExcludedProvider` |
| Doctor shopping | At least N prescribers in 90 days (needs patient data) | `DoctorShopping` |
| Card sharing | One member ID served in distant places on the same day (needs patient data) | `CardSharing` |
| Age and sex vs. procedure | CMS age and sex edits, e.g. a pregnancy code for a male patient | `AgeSexProcedureMismatch` |
| Impossible day | More than 24 hours of time-based services by one provider on one day, across claims | `ImpossibleDay` |
| Timely filing | Received after the state's deadline, counted from the date of service | `TimelyFiling` |

## Why Python

Decided 2026-11-20. Training and the scoring service are written in Python; the Haskell engine calls the service through `ML_SCORER_URL` as it does now, and Phoenix stays as it is.

Python was compared with the two languages already in the app, against what these ten models need:

| Need | Python | Elixir (Nx, Scholar, Explorer, EXGBoost) | Haskell |
|---|---|---|---|
| Isolation Forest (model 1) | scikit-learn, mature | Not available; would be written by hand | Written by hand |
| Gradient boosting and calibration (models 4, 9, 10) | LightGBM or XGBoost, calibration built in | EXGBoost, younger; calibration by hand | Not available |
| Change-point detection (model 3) | `ruptures` and others | Written by hand | Written by hand |
| Graph analysis (model 5) | NetworkX | `libgraph`, basic | `fgl`, basic |
| Per-claim reasons, the `top_factors` an analyst sees | SHAP, the standard method | No equivalent | No equivalent |
| Data files of several GB | Polars, DuckDB | Explorer (built on Polars) | Weak |
| ML principles shown in a familiar form | scikit-learn, as in most courses and texts | Less familiar | Unfamiliar |
| No new language or service | Adds both | Yes | Yes |
| The later LLM step | Every SDK and local-model tool | Plain HTTP works | Plain HTTP works |

**The deciding reasons:** the algorithms the plan names exist in Python and are mature, and SHAP gives the per-claim reasons that Edition 2 depends on (an analyst has to see why a claim scored high). Neither Elixir nor Haskell has an equivalent today. Haskell would mean writing the algorithms from scratch; Elixir was the credible alternative, keeping the app to two languages at the cost of simpler models and hand-written explanations.

**The cost** is a third service to start, test and run (`scripts/start.sh` and the test scripts start it too). It is accepted because the same service will host the later LLM step, and because Python is the language the developer knows best.

All the libraries above are open source, in line with the decision to avoid commercial services for now.

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

**Future data sources** (not in this plan; each would close a gap the rules and models cannot):

| Source | What it would catch |
|---|---|
| Member eligibility (enrolled on the date of service?) | Services billed for members not covered at the time |
| Death records | Services billed after a member or provider died |
| State Medicaid provider enrollment and license status | Providers not enrolled, or with a suspended license (the LEIE covers federal exclusions only) |
| Pharmacy claims | Most prescription-drug schemes |
| Patient-level claim history | Doctor shopping, card sharing, shared-patient networks (needs the patient-data decision) |

## Storage and database

Each source is stored where it is used. Phoenix owns every database table, through Ecto migrations, as with `nppes_providers`; Python reads and writes rows but never changes the schema. No existing table changes.

The raw HHS Medicaid Provider Spending data (several GB, exact size confirmed before download) stays out of the database: files in `python_ml/data/`, converted once to Parquet. Only training reads these rows, all at once, and DuckDB or Polars does that faster than Postgres, which keeps the app's database small.

### New tables

| Table | Phase | Written by | Read by | Holds |
|---|---|---|---|---|
| `leie_exclusions` | 1 | A monthly importer, like the NPPES refresh (~80,000 rows, ~15 MB; OIG updates it monthly) | ExcludedProvider rule; Python training | One row per excluded provider: NPI, name, exclusion type, exclusion date, reinstatement date |
| `ml_model_versions` | 2 | Python training | Scoring service; Phoenix | One row per trained version: model name (the catalogue name), version, data years, test results, model card link, status `candidate`, `active` or `retired` |
| `ml_provider_scores` | 3 | Python training | Scoring service | One row per provider per model version (~1 million per version): NPI, score, top reasons, peer group, or *not assessed* with the reason |
| `claim_ml_results` | 3–4 | Phoenix, from the engine's reply | Claim page; Python (labels) | One row per claim per model: model and version, score, band, reasons, or *not assessed* |
| `analyst_decisions` | 4 (or earlier, see decisions below) | Phoenix, when an analyst decides | Claim page; Python (labels for models 9–10) | Claim, analyst, decision (for example *problem confirmed* or *legitimate*), note, time, why the claim was reviewed (*flagged*, or *random audit*), and a snapshot of the rule findings and ML scores shown when deciding. Rows are added, never changed. |

Python reads `nppes_providers` straight from Postgres for peer groups, so nothing is copied.

### How the models use the database

**Training** (on the development Mac, occasionally):

1. Read the HHS Parquet files, `nppes_providers` (specialty, state, tenure) and `leie_exclusions` (labels).
2. Train and evaluate; save the model file in `python_ml/artifacts/`.
3. Write a `candidate` row to `ml_model_versions` and that version's rows to `ml_provider_scores`.
4. After the model card is reviewed, mark the version `active`. Only then does scoring use it, and the catalogue entry can move from *Not connected* to *Active*.

**Scoring** (each claim):

1. Phoenix sends the claims to the engine; the engine calls the Python service.
2. The service looks up the billing provider in `ml_provider_scores` for each active version (models 1–5), and computes claim-level models (6–8) from the claim itself.
3. The result returns through the engine to Phoenix, which stores it in `claim_ml_results`. A provider not in the data is stored as *not assessed*, never as low risk.

**Retraining** reads `analyst_decisions` together with `claim_ml_results` as labels. That is how the models learn from use: as a new, reviewed version, never automatically.

[DATABASE_ERD.md](DATABASE_ERD.md) gains each table when it is added.

## Phases

### Phase 1: data in place

- A download script for the HHS Medicaid spending file and the LEIE, saving into `python_ml/data/`, outside git.
- The `leie_exclusions` table and its monthly importer (see [Decisions on the database](#decisions-on-the-database)).
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
6. **Save version 1:** the model file, its version, the data years used, and a model card; its `ml_model_versions` row starts as `candidate`.

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
- **Database:** the `ml_provider_scores` and `claim_ml_results` tables, and Python's own database login.
- **Docs:** update ARCHITECTURE (three services) per item #10.

**Done when:** an uploaded batch shows ML results end to end, and all test suites pass.

### Phase 4: show it in the app

- On each claim, the ML finding appears as a recommendation: band, score, top reasons, model version. A claim the model could not assess is shown as such.
- The analyst's decision on a claim is stored in `analyst_decisions` with the model version that scored it, unless that table was built earlier. These decisions become training labels for future retraining.
- The random audit sample starts (see [Limits of the whole system](#limits-of-the-whole-system)).
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
- **Measure what is missed.** A small random share of unflagged claims is reviewed too, so misses can be estimated and labels are not limited to what the rules already catch.

## Limits of the whole system

The Default Rules, BA Rules and ML Models together do not catch every anomalous claim, and are not meant to: their job is to catch the common patterns and send analysts to the riskiest claims first (reviewed 2026-11-20).

- **Beyond claims data.** Services never provided but billed at normal codes and volumes, medical necessity, kickbacks, and stolen provider identities can look normal on a claim. They need investigators, member contact or medical-records audits (see [Out of scope](#out-of-scope)).
- **Data the app lacks.** Eligibility, death records, state enrollment, pharmacy claims and patient-level history; see *Future data sources* under [Data](#data).
- **Misses can't be seen directly.** Every label from analyst decisions comes from claims that were already flagged, so models trained only on them learn to catch what the rules already catch. A **random audit sample** fixes this: analysts also review a small random share (for example 1%) of claims nothing flagged. That estimates the miss rate and gives unbiased labels, which matters most for AnalystOutcomeModel and RuleEffectivenessModel. Each such review is recorded in `analyst_decisions` as *random audit*.

## Where things live

Decided 2026-11-20. The Python service sits at the top level beside the other two, named in the same *language_role* pattern, so the tree shows three services in three languages. Each is built and tested on its own, and they talk only over HTTP.

```
medicaid_claims_checker/
├── phoenix_web/        Elixir: the web app (UI, database, uploads)
├── haskell_engine/     Haskell: the rule engine
├── python_ml/          Python: ML training and the scoring service
├── mock_data/          shared test files
├── docs/               shared docs; model cards in docs/models/
└── scripts/            start, set up and test all services
```

Inside `python_ml/`, one `uv` project with two parts that share the feature code, so training and scoring always compute features the same way:

```
python_ml/
├── pyproject.toml      dependencies, pinned (uv.lock beside it)
├── README.md           how to train, run the service and test
├── src/claims_ml/
│   ├── data/           download the HHS and LEIE files; read NPPES from Postgres
│   ├── features/       per-provider and per-claim features (shared)
│   ├── models/         one module per catalogue ML Model
│   ├── training/       train, evaluate, write model cards and ml_provider_scores
│   └── service/        FastAPI scorer implementing the engine's v1.0 contract
├── tests/
├── data/               downloaded files (out of git)
└── artifacts/          trained model files, by version (out of git)
```

- Only `service/` runs alongside the app. Training runs on the development Mac when a model is retrained.
- `artifacts/` holds trained model files; the name keeps them apart from the model code in `src/claims_ml/models/`.
- `.gitignore` gains `python_ml/data/` and `python_ml/artifacts/`. Model cards stay in git under `docs/models/`.
- When the service is added, `scripts/start.sh` and `scripts/test.sh` start it too, and ARCHITECTURE and the README describe three services ([ML_INTEGRATION_NOTES.md](ML_INTEGRATION_NOTES.md), item 10).

## Decisions needed before Phase 1

1. ~~Is the HHS Medicaid Provider Spending data acceptable as the training data?~~ **Yes** (decided 2026-11-20).
2. ~~Is the folder layout above acceptable?~~ **Yes**, as `python_ml/` (decided 2026-11-20).
3. ~~Is the order acceptable: anomaly model first, supervised model fifth, the LLM afterwards?~~ **Yes** (decided 2026-11-20), as in [The ML Models](#the-ml-models): models 1–5 on public data, 6–8 once real claims accumulate, 9–10 once analysts have made enough decisions, the LLM step last.

## Decisions on the database

Open. Each has a recommendation.

1. **Who loads the exclusion list?** Recommended: an Elixir importer built like the NPPES refresh, with a monthly schedule and a status panel in Settings. The ExcludedProvider rule needs the table whether or not ML runs; Python only reads it.
2. **Where do ML results go?** Recommended: the separate `claim_ml_results` table, not the engine's `evaluation_report` on `edi_files`, so each model's version stays queryable for training labels and audits.
3. **What can Python access?** Recommended: its own Postgres login that can read `nppes_providers`, `leie_exclusions` and `analyst_decisions`, and write only the `ml_*` tables. No access to `edi_files` until models 6–8; those rows hold patient data, so that access is a separate decision made then.
4. **When is `analyst_decisions` built?** It is the missing piece of Edition 2's "the system recommends, an analyst decides": the app has nowhere to record a decision today. It needs a page for analysts as well as the table, and could be built before or alongside the ML work rather than in Phase 4.

## Logging and audit

App-wide work, not specific to ML, recorded here because it should be in place before the ML results and analyst decisions are (reviewed 2026-11-20). Open; to be scheduled.

**Today:**

- **Phoenix** uses Elixir's standard logger: plain-text lines with a timestamp and request ID; debug level in development, info in production. About 75 log calls, mostly file fetching, the NPPES import and batch-evaluation failures. Passwords and CSRF tokens are masked.
- **The engine** logs only its startup lines and two ML warnings: no line per request, and no errors, timeouts, refused requests or rate-limit hits.
- **`scripts/start.sh`** writes `logs/backend.log` and `logs/frontend.log` (out of git) and overwrites them on every start.
- **The database** already keeps a durable record of processing: `batches` (status, duplicates refused, files rejected), each claim's status and error in `edi_files`, the NPPES refresh's last status, and the background-job table.

**Gaps, most important first:**

1. **No audit trail.** Nothing records who logged in, who viewed which claim, who edited or switched off a rule, or what an admin changed. HIPAA's Security Rule requires audit controls that record access to systems holding patient data.
2. **The engine is silent,** and no request ID links a Phoenix log line to the engine call it made.
3. **The development log holds sensitive values.** At debug level Phoenix logs each LiveView session, including the login session token, and duplicate notices name claim IDs and files. Production's info level leaves out the session lines.
4. **No history or search.** Logs are overwritten on restart and are plain text.
5. **Coming work needs more.** The scoring service and the LLM step must record what they produced: ML scores carry model versions in `claim_ml_results`; LLM prompts and outputs need the same treatment.

**Planned:**

| # | Change | Where |
|---|---|---|
| 1 | An `audit_events` table: one row per action (user, action, target, time), rows only ever added. It covers logins, claim views, rule edits and switches, admin changes, and later analyst decisions and random-audit reviews. It is built with or before `analyst_decisions`. | Phoenix, new table |
| 2 | One log line per engine request: path, status, duration and claim count, never claim contents. Phoenix sends its request ID with each call, and the engine logs it. | Engine and Phoenix |
| 3 | Keep log history: append on start and rotate old files, instead of overwriting. | `scripts/start.sh` |
| 4 | Keep the development debug level, and note in the README that `logs/` holds session tokens and claim IDs and must not be shared. | README |
| 5 | The Python service logs one line per scoring request (model versions used, duration, no claim contents); the LLM step records each prompt, model and output with the claim or rule it concerned. | `python_ml/`, later the LLM step |

## Out of scope

- The full, claim-level T-MSIS files and any data-use agreement.
- The LLM scorer (it follows this plan).
- Automatic retraining.
- Schemes claims data cannot show (services never provided, medical necessity, kickbacks, stolen provider identities). They belong to investigation, member verification and records audits.
- The future data sources listed under [Data](#data).
