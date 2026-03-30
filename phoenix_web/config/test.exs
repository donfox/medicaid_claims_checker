import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "OUSZpXgWfdVui+SaauV/FdI48KGr0dWpD1UoDeYvVEWp2F50ScwJFUZNs2q4a9w0",
  server: false

# In test we don't send emails
config :medicaid_claims_checker, MedicaidClaimsChecker.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Configure database for tests
config :medicaid_claims_checker, MedicaidClaimsChecker.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "medicaid_claims_checker_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Skip async evaluation in tests — evaluation is tested directly via Evaluator
config :medicaid_claims_checker, skip_async_evaluation: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
