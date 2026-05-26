import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/medicaid_claims_checker start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint, server: true
end

config :medicaid_claims_checker,
  rule_engine_url: System.get_env("RULE_ENGINE_URL") || "http://localhost:8080",
  rule_engine_secret:
    System.get_env("RULE_ENGINE_SECRET") ||
      if(config_env() == :dev, do: "dev-secret-change-in-production", else: "")

if config_env() == :prod and (System.get_env("RULE_ENGINE_SECRET") || "") == "" do
  raise """
  environment variable RULE_ENGINE_SECRET is missing or empty.
  Set it to a securely random value shared with the Haskell rule engine.
  """
end

if System.get_env("BREVO_MAIL_USERNAME") do
  config :swoosh, :api_client, Swoosh.ApiClient.Finch

  config :medicaid_claims_checker, MedicaidClaimsChecker.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: "smtp-relay.brevo.com",
    port: 587,
    username: System.get_env("BREVO_MAIL_USERNAME"),
    password: System.get_env("BREVO_MAIL_PASSWORD"),
    tls: :always,
    auth: :always
end

if System.get_env("SFTP_HOST") do
  config :medicaid_claims_checker, :sftp,
    host: System.get_env("SFTP_HOST"),
    username: System.get_env("SFTP_USERNAME"),
    password: System.get_env("SFTP_PASSWORD"),
    port: String.to_integer(System.get_env("SFTP_PORT") || "22")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :medicaid_claims_checker, MedicaidClaimsChecker.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :medicaid_claims_checker, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {127, 0, 0, 1},
      # ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :medicaid_claims_checker, MedicaidClaimsCheckerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: :crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()
      """

  config :medicaid_claims_checker, MedicaidClaimsChecker.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM,
                tag: "AES.GCM.V1",
                key: Base.decode64!(cloak_key)}
    ]
end
