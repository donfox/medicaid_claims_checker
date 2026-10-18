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
end
