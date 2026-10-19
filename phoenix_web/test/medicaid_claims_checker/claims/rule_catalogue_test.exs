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

  test "accepts the Retired status" do
    assert %{status: "Retired"} = entry!("Retired")
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

  test "a Retired entry can't be toggled back on" do
    retired = entry!("Retired")
    assert {:error, :retired} = Claims.toggle_catalogue_status(retired)
    assert %{status: "Retired"} = Claims.get_catalogue_entry(retired.id)
  end
end
