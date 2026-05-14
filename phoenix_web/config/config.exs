# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :medicaid_claims_checker, :scopes,
  user: [
    default: true,
    module: MedicaidClaimsChecker.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: MedicaidClaimsChecker.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :medicaid_claims_checker,
  ecto_repos: [MedicaidClaimsChecker.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Register .x12 MIME type for LiveView uploads
config :mime, :types, %{
  "application/x-x12" => ["x12", "edi"]
}

# Configures the endpoint
config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MedicaidClaimsCheckerWeb.ErrorHTML, json: MedicaidClaimsCheckerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MedicaidClaimsChecker.PubSub,
  live_view: [signing_salt: "4SAj6dYS"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :medicaid_claims_checker, MedicaidClaimsChecker.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  medicaid_claims_checker: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  medicaid_claims_checker: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :medicaid_claims_checker, MedicaidClaimsChecker.Scheduler,
  jobs: [],
  timezone: "America/New_York"

config :medicaid_claims_checker, Oban,
  repo: MedicaidClaimsChecker.Repo,
  queues: [batch_evaluation: 4]

config :medicaid_claims_checker, :config_poller, poll_interval_ms: 60_000

config :medicaid_claims_checker, :remote_fetcher,
  download_timeout_ms: 60_000,
  max_file_size_bytes: 100_000_000,
  allowed_extensions: [".x12", ".edi", ".txt"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
