defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.NotCheckedRulesTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims.{Batch, EdiFile}
  alias MedicaidClaimsChecker.Repo

  setup %{conn: conn} do
    # Registration only; avoids the login-email path (no mail in tests).
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  defp result(name, undecided) do
    %{
      "resultRuleName" => name,
      "resultMatched" => false,
      "resultAction" => nil,
      "resultDetails" =>
        if(undecided,
          do:
            "Rule did not match: missing or unusable data (service_lines[].date_of_service missing)",
          else: "Rule did not match"
        ),
      "resultUndecided" => undecided
    }
  end

  defp insert_batch_with_files do
    batch =
      Repo.insert!(%Batch{
        batch_id: Ecto.UUID.generate(),
        batch_name: "Missing data batch",
        source: "manual_upload",
        file_count: 2,
        status: "completed"
      })

    incomplete =
      Repo.insert!(%EdiFile{
        batch_id: batch.id,
        filename: "incomplete.json",
        file_path: "incomplete.json",
        status: "evaluated",
        evaluation_report: %{
          "overallRisk" => "LowRisk",
          "matchedRules" => 0,
          "undecidedRules" => 1,
          "totalRules" => 2,
          "results" => [result("FutureServiceDate", true), result("HighValueClaim", false)]
        }
      })

    complete =
      Repo.insert!(%EdiFile{
        batch_id: batch.id,
        filename: "complete.json",
        file_path: "complete.json",
        status: "evaluated",
        # Stored before the engine reported undecided rules: no such fields.
        evaluation_report: %{
          "overallRisk" => "LowRisk",
          "matchedRules" => 0,
          "totalRules" => 1,
          "results" => [Map.delete(result("HighValueClaim", false), "resultUndecided")]
        }
      })

    {batch, incomplete, complete}
  end

  defp open_batch(conn, batch) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[aria-controls=batch-history-panel]") |> render_click()

    view
    |> element(~s(button[phx-click="toggle_batch_detail"][phx-value-id="#{batch.id}"]))
    |> render_click()

    view
  end

  test "a claim with undecided rules is not shown as clean", %{conn: conn} do
    {batch, incomplete, complete} = insert_batch_with_files()
    view = open_batch(conn, batch)

    assert render(view) =~ "1 not checked (missing data)"

    html = view |> element(~s(tr[phx-value-id="#{incomplete.id}"])) |> render_click()
    assert html =~ "Not checked — missing or unusable data"
    assert html =~ "FutureServiceDate"
    assert html =~ "FutureServiceDate</span>: service_lines[].date_of_service missing"
    refute html =~ "claim is clean"

    view |> element(~s(tr[phx-value-id="#{incomplete.id}"])) |> render_click()
    html = view |> element(~s(tr[phx-value-id="#{complete.id}"])) |> render_click()
    assert html =~ "claim is clean"
    refute html =~ "Not checked — missing or unusable data"
  end

  test "the Clean filter leaves out claims with undecided rules", %{conn: conn} do
    {batch, _incomplete, _complete} = insert_batch_with_files()
    view = open_batch(conn, batch)

    html = view |> element(~s(button[phx-click="filter_batch_risk"]), "Clean") |> render_click()

    assert html =~ "complete.json"
    refute html =~ "incomplete.json"
  end

  test "a report stored before the engine named fields still lists the rule", %{conn: conn} do
    {batch, incomplete, _complete} = insert_batch_with_files()

    old_result =
      Map.put(
        result("FutureServiceDate", true),
        "resultDetails",
        "Rule did not match: missing or unusable data"
      )

    incomplete
    |> Ecto.Changeset.change(
      evaluation_report: %{incomplete.evaluation_report | "results" => [old_result]}
    )
    |> Repo.update!()

    view = open_batch(conn, batch)
    html = view |> element(~s(tr[phx-value-id="#{incomplete.id}"])) |> render_click()

    assert html =~ "FutureServiceDate"
    refute html =~ "FutureServiceDate</span>:"
  end
end
