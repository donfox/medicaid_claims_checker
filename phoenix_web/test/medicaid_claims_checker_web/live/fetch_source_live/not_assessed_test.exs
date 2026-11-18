defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.NotAssessedTest do
  # A claim the rule engine could not check (e.g. it timed out) is shown as
  # not assessed in Jobs History: never CLEAN, never "claim is clean".
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims.{Batch, EdiFile}
  alias MedicaidClaimsChecker.Repo

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  defp insert_batch_with_files do
    batch =
      Repo.insert!(%Batch{
        batch_id: Ecto.UUID.generate(),
        batch_name: "Timeout batch",
        source: "manual_upload",
        file_count: 2,
        status: "completed"
      })

    slow =
      Repo.insert!(%EdiFile{
        batch_id: batch.id,
        filename: "slow.json",
        file_path: "slow.json",
        status: "not_assessed",
        evaluation_report: nil,
        error_message: "evaluation timed out after 30 s",
        error_details: %{"reason" => "timeout"}
      })

    ok =
      Repo.insert!(%EdiFile{
        batch_id: batch.id,
        filename: "ok.json",
        file_path: "ok.json",
        status: "evaluated",
        evaluation_report: %{
          "overallRisk" => "LowRisk",
          "matchedRules" => 0,
          "totalRules" => 1,
          "results" => []
        }
      })

    {batch, slow, ok}
  end

  defp open_batch(conn, batch) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[aria-controls=batch-history-panel]") |> render_click()

    view
    |> element(~s(button[phx-click="toggle_batch_detail"][phx-value-id="#{batch.id}"]))
    |> render_click()

    view
  end

  test "a timed-out claim shows as not assessed with the reason, never clean", %{conn: conn} do
    {batch, slow, _ok} = insert_batch_with_files()
    view = open_batch(conn, batch)

    assert has_element?(view, "#not-assessed-#{slow.id}", "NOT ASSESSED")
    assert render(view) =~ "Not assessed: evaluation timed out after 30 s"

    html = view |> element(~s(tr[phx-value-id="#{slow.id}"])) |> render_click()
    assert has_element?(view, "#not-assessed-detail-#{slow.id}")
    assert html =~ "Not assessed — the rules were not checked"
    assert html =~ "an analyst must review it"
    refute html =~ "claim is clean"

    row = view |> element(~s(tr[phx-value-id="#{slow.id}"])) |> render()
    assert row =~ "Not assessed"
    refute row =~ "LowRisk"
    refute row =~ "CLEAN"
    refute row =~ "No rules triggered"
  end

  test "the Clean filter leaves out a not-assessed claim; its own filter shows it",
       %{conn: conn} do
    {batch, _slow, _ok} = insert_batch_with_files()
    view = open_batch(conn, batch)

    html = view |> element(~s(button[phx-click="filter_batch_risk"]), "Clean") |> render_click()
    assert html =~ "ok.json"
    refute html =~ "slow.json"

    html =
      view
      |> element(~s(button[phx-click="filter_batch_risk"][phx-value-level="NotAssessed"]))
      |> render_click()

    assert html =~ "slow.json"
    refute html =~ "ok.json"
  end
end
