# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :medicaid_claims_checker,
  ecto_repos: [MedicaidClaimsChecker.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Register .x12 MIME type for LiveView uploads
config :mime, :types, %{
  "application/x-x12" => ["x12"]
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
