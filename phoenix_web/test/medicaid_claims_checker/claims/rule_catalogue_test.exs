defmodule MedicaidClaimsChecker.Claims.RuleCatalogueTest do
  use MedicaidClaimsChecker.DataCase, async: true

  alias MedicaidClaimsChecker.Claims

  defp entry!(status) do
    {:ok, entry} =
      Claims.create_catalogue_entry(%{
        name: "Rule#{System.unique_integer([:positive])}",
        description: "",
        entry_type: "BA Rule",
        status: status
      })

    entry
  end

  defp with_rule!(status, active) do
    entry = entry!(status)

    {:ok, _rule} =
      Claims.create_business_rule(%{
        name: entry.name,
        rule_text: ~s|RULE r "d" WHEN financial.claim_amount > 1 THEN REQUIRE_REVIEW "x";|,
        active: active
      })

    entry
  end

  defp active?(entry), do: Claims.get_business_rule_by_name(entry.name).active

  test "accepts the Retired status" do
    assert %{status: "Retired"} = entry!("Retired")
  end

  test "accepts the Not connected status" do
    assert %{status: "Not connected"} = entry!("Not connected")
  end

  test "a Not connected entry can't be toggled on" do
    entry = entry!("Not connected")
    assert {:error, :not_connected} = Claims.toggle_catalogue_status(entry)
    assert %{status: "Not connected"} = Claims.get_catalogue_entry(entry.id)
  end

  test "rejects an unknown status" do
    assert {:error, changeset} =
             Claims.create_catalogue_entry(%{
               name: "Odd",
               entry_type: "BA Rule",
               status: "Paused"
             })

    assert %{status: [_]} = errors_on(changeset)
  end

  test "toggling switches Active and Inactive" do
    assert {:ok, %{status: "Inactive"} = inactive} =
             Claims.toggle_catalogue_status(entry!("Active"))

    assert {:ok, %{status: "Active"}} = Claims.toggle_catalogue_status(inactive)
  end

  describe "toggling keeps business_rules.active in step" do
    test "switching off and on sets active false, then true" do
      entry = with_rule!("Active", true)

      assert {:ok, %{status: "Inactive"} = off} = Claims.toggle_catalogue_status(entry)
      refute active?(entry)

      assert {:ok, %{status: "Active"}} = Claims.toggle_catalogue_status(off)
      assert active?(entry)
    end

    test "a rule that had drifted out of step is brought back in step" do
      # Catalogue says Inactive but the rule is still active: switching the
      # entry on must leave it active, not flip it off.
      entry = with_rule!("Inactive", true)

      assert {:ok, %{status: "Active"}} = Claims.toggle_catalogue_status(entry)
      assert active?(entry)
    end

    test "an entry with no business_rules row only changes status" do
      assert {:ok, %{status: "Inactive"}} = Claims.toggle_catalogue_status(entry!("Active"))
    end
  end

  test "a Retired entry can't be toggled back on" do
    retired = entry!("Retired")
    assert {:error, :retired} = Claims.toggle_catalogue_status(retired)
    assert %{status: "Retired"} = Claims.get_catalogue_entry(retired.id)
  end
end
