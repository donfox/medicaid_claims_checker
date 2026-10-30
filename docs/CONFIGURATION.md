# Configuration

Every setting the app reads, where it is read, and its default. Settings are
environment variables unless noted. For local development none of them need
setting: `./start.sh` and the development config supply working defaults.

## Shared by both services

| Variable | Default | What it does |
|---|---|---|
| `RULE_ENGINE_SECRET` | `dev-secret-change-in-production` in development (set by `start.sh` and `config/runtime.exs`) | The shared secret Phoenix sends to the engine as a Bearer token. Both services must have the same value. The engine refuses every request except `/api/health` when it is unset; a production Phoenix will not start without it. |

## Haskell engine

Read by `haskell_engine/app/Main.hs` and `src/Claims/ListenConfig.hs` at
startup, except the ML settings, which `src/Claims/MLClient.hs` and
`src/Claims/Pipeline.hs` read on each `/api/evaluate` request.

| Variable | Default | What it does |
|---|---|---|
| `ENGINE_HOST` | `127.0.0.1` | Address to listen on. Without TLS only a loopback address is allowed. |
| `ENGINE_PORT` | `8080` | Port to listen on. |
| `RULE_ENGINE_TLS_CERT`, `RULE_ENGINE_TLS_KEY` | unset | Certificate and key files. With both set the engine serves HTTPS and may listen on any address. See [haskell_engine/README.md](../haskell_engine/README.md#listening-and-tls); `haskell_engine/gen-dev-tls.sh` makes a development certificate. |
| `ENGINE_RATE_LIMIT` | `1000` | Most requests one client IP may make per 60 seconds; `/api/health` is not counted. `./test.sh` raises it for its own engine. |
| `ML_SCORER_URL` | unset | The ML scoring service `/api/evaluate` calls. Unset, a fixed stand-in score is used. Must be `https://`; private and cloud-metadata addresses are refused. |
| `ML_TIMEOUT_MS` | `120` | How long to wait for the scorer, in milliseconds. Too short for a real model service; see [ML_INTEGRATION_NOTES.md](ML_INTEGRATION_NOTES.md). |
| `ALLOW_ML_TEST_OVERRIDE` | unset | When `true`, a claim containing `"_mlStatus": "error"` skips the scorer as if it had failed. For tests only. |

Phoenix uses only `/api/batch-evaluate`, which never calls the ML scorer, so the
ML settings do not affect the app today.

## Phoenix app

Read by `phoenix_web/config/runtime.exs` unless noted.

### Always

| Variable | Default | What it does |
|---|---|---|
| `RULE_ENGINE_URL` | `http://localhost:8080` | Where the engine is. Use `https://` when the engine serves TLS. |
| `RULE_ENGINE_CA_CERT` | unset | CA certificate file that signed the engine's certificate, when it is not from a public CA. |
| `SFTP_HOST`, `SFTP_USERNAME`, `SFTP_PASSWORD`, `SFTP_PORT` | unset; port `22` | Default SFTP connection for fetch sources. A source's own address and saved credentials take priority. |
| `TENANT_ID` | `default_tenant` | Tenant name the Rules page sends in evaluation requests (read in `RuleLive.PayloadBuilder`). |
| `PORT` | `4000` | Port the web app listens on (development and production). |

### Production only

Phoenix will not start in production without the first three.

| Variable | Default | What it does |
|---|---|---|
| `DATABASE_URL` | none (required) | The database, as `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | none (required) | Signs and encrypts cookies. Make one with `mix phx.gen.secret`. |
| `CLOAK_KEY` | none (required) | Key that encrypts saved fetch-source credentials, base64 of 32 random bytes. Changing it makes saved credentials unreadable. |
| `PHX_HOST` | `example.com` | Public host name used in generated links. |
| `PHX_SERVER` | unset | Set to start the web server in a release. |
| `POOL_SIZE` | `10` | Database connections. |
| `ECTO_IPV6` | unset | `true` or `1` to reach the database over IPv6. |
| `DNS_CLUSTER_QUERY` | unset | DNS name for clustering several app nodes. |

### Settings in the config files

These are not environment variables; they live in `phoenix_web/config/`.

| Setting | Where | What it does |
|---|---|---|
| `allow_test_resubmission: true` | `dev.exs` | Shows the "Test upload: allow re-submission" checkbox on Manual Upload. Development only. |
| Cloak development key | `dev.exs`, `test.exs` | A fixed, all-zero key so development and tests work without `CLOAK_KEY`. Never use it in production. |
| `:databricks` (`host`, `token`) | not set | Needed only for Databricks fetch sources; add it to a config file to use them. |
| Oban `batch_evaluation` queue | `config.exs` | One concurrent batch evaluation per CPU core, matching the engine's worker pool. |
| `:config_poller` | `config.exs` | Re-reads the fetch sources and schedules every 60 seconds and updates the scheduled fetch jobs. |

## Scripts

| Script | Options | Notes |
|---|---|---|
| `./setup.sh` | none | Builds the engine, installs Phoenix dependencies, creates, migrates and seeds the database. Safe to run again. |
| `./start.sh` | `--install`, `--backend`, `--frontend`, `--foreground` (`-f`) | Starts both services, or one. Frees ports 4000 and 8080 first. Logs go to `logs/`. |
| `./test.sh` | use-case IDs, such as `R5 N7` | Starts its own engine on `TEST_ENGINE_PORT` (default `8092`) and runs the frontend use-case tests. |
