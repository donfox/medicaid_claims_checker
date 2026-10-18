defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.JsonUploadTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims.Batch
  alias MedicaidClaimsChecker.Repo

  @fixtures Path.expand("../../../fixtures", __DIR__)

  setup %{conn: conn} do
    # Registration only; avoids the login-email path (no mail in tests).
    user = AccountsFixtures.unconfirmed_user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  defp upload(conn, files) do
    {:ok, view, _html} = live(conn, ~p"/")

    for {name, content} <- files do
      view
      |> file_input("#manual-upload-form", :manual_files, [
        %{name: name, content: content, type: "application/json"}
      ])
      |> render_upload(name)
    end

    view |> form("#manual-upload-form") |> render_submit()
  end

  test "a file with no claim is refused and no batch is created", %{conn: conn} do
    content = File.read!(Path.join(@fixtures, "batches/batch_redundancy_extended.json"))

    html = upload(conn, [{"batch_redundancy_extended.json", content}])

    assert html =~ "No claims found in the uploaded JSON files."
    assert html =~ "batch_redundancy_extended.json: an engine test request"
    assert Repo.aggregate(Batch, :count) == 0
  end

  test "claims are accepted and the refused file is named", %{conn: conn} do
    claim = File.read!(Path.join(@fixtures, "claims/acceptable/claim_routine_office_visit.json"))

    html = upload(conn, [{"claim.json", claim}, {"notes.json", ~s({"name": "x"})}])

    assert html =~ "1 JSON claim(s) submitted for evaluation"
    assert html =~ "Not accepted: notes.json: no claim found"
    assert Repo.aggregate(Batch, :count) == 1
  end
end
