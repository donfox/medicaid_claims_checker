defmodule MedicaidClaimsChecker.Claims.NppesProviderTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.NppesProvider

  defp provider(deact, react \\ nil),
    do: %NppesProvider{npi: "1234567893", deactivation_date: deact, reactivation_date: react}

  describe "active_on_date?/2" do
    test "a provider never deactivated is active" do
      assert NppesProvider.active_on_date?(provider(nil), ~D[2026-01-15])
    end

    test "a deactivated provider is active up to and on the deactivation date" do
      p = provider(~D[2023-06-15])
      assert NppesProvider.active_on_date?(p, ~D[2023-06-14])
      assert NppesProvider.active_on_date?(p, ~D[2023-06-15])
      refute NppesProvider.active_on_date?(p, ~D[2023-06-16])
    end

    test "a reactivated provider is active from the reactivation date on" do
      p = provider(~D[2022-03-01], ~D[2022-09-15])
      assert NppesProvider.active_on_date?(p, ~D[2022-02-01])
      refute NppesProvider.active_on_date?(p, ~D[2022-06-01])
      assert NppesProvider.active_on_date?(p, ~D[2022-09-15])
      assert NppesProvider.active_on_date?(p, ~D[2026-01-15])
    end

    test "a reactivation date before the deactivation does not reinstate" do
      p = provider(~D[2022-09-15], ~D[2022-03-01])
      refute NppesProvider.active_on_date?(p, ~D[2026-01-15])
    end
  end

  describe "issued_by?/2" do
    test "a service before the NPI was issued fails; on or after passes" do
      p = %NppesProvider{npi: "1234567893", enumeration_date: ~D[2018-04-02]}
      refute NppesProvider.issued_by?(p, ~D[2018-04-01])
      assert NppesProvider.issued_by?(p, ~D[2018-04-02])
      assert NppesProvider.issued_by?(%NppesProvider{npi: "1234567893"}, ~D[2001-01-01])
    end
  end

  describe "listed_on?/2" do
    test "services before the NPI was dropped from NPPES pass; on or after fail" do
      p = %NppesProvider{npi: "1234567893", dropped_on: ~D[2026-10-17]}
      assert NppesProvider.listed_on?(p, ~D[2026-03-10])
      refute NppesProvider.listed_on?(p, ~D[2026-10-17])
      assert NppesProvider.listed_on?(%NppesProvider{npi: "1234567893"}, ~D[2026-10-17])
    end
  end
end
