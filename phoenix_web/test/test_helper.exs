# :integration and :use_case tests need the Haskell engine running; see
# test/use_cases/ and ./test.sh at the repo root.
ExUnit.start(exclude: [:integration, :use_case])
Ecto.Adapters.SQL.Sandbox.mode(MedicaidClaimsChecker.Repo, :manual)
