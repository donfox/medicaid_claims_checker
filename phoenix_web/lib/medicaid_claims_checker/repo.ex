defmodule MedicaidClaimsChecker.Repo do
  use Ecto.Repo,
    otp_app: :medicaid_claims_checker,
    adapter: Ecto.Adapters.Postgres
end
