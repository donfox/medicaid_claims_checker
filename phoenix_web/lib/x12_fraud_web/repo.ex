defmodule X12FraudWeb.Repo do
  use Ecto.Repo,
    otp_app: :x12_fraud_web,
    adapter: Ecto.Adapters.Postgres
end
