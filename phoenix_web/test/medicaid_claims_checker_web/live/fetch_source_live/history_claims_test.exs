defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.HistoryClaimsTest do
  # Jobs History loads a batch's claims only while the batch is expanded,
  # at most 500 of them, flagged first, filtered in the database.
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims.{Batch, EdiFile}
  alias MedicaidClaimsChecker.Repo

  setup %{conn: conn} do
    %{conn: log_in_user(conn, AccountsFixtures.user_fixture())}
  end

  defp report(risk, matched, undecided? \\ false) do
    %{
      "overallRisk" => risk,
      "matchedRules" => matched,
      "results" => [
        %{
          "resultRuleName" => "R",
          "resultMatched" => matched > 0,
          "resultUndecided" => undecided?
        }
      ]
    }
  end

  # name => {status, report}
  defp insert_batch(claims) do
    now = DateTime.utc_now(:second)

    batch =
      Repo.insert!(%Batch{
        batch_id: Ecto.UUID.generate(),
        batch_name: "History test",
        source: "manual_upload",
        file_count: length(claims),
        status: "completed"
      })

    rows =
      for {name, {status, report}} <- claims do
        %{
          batch_id: batch.id,
          filename: name,
          file_path: name,
          status: status,
          json_output: %{"claim_id" => name},
          evaluation_report: report,
          inserted_at: now,
          updated_at: now
        }
      end

    rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(EdiFile, &1))
    batch
  end

  defp open_history(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[aria-controls=batch-history-panel]") |> render_click()
    view
  end

  defp expand(view, batch),
    do: render_click(view, "toggle_batch_detail", %{"id" => "#{batch.id}"})

  test "a collapsed batch loads no claims; expanding loads them, collapsing drops them", %{
    conn: conn
  } do
    batch = insert_batch([{"clean_one.json", {"evaluated", report("LowRisk", 0)}}])
    view = open_history(conn)

    refute render(view) =~ "clean_one"
    assert :sys.get_state(view.pid).socket.assigns.batch_files == %{}

    assert expand(view, batch) =~ "clean_one"
    expand(view, batch)
    assert :sys.get_state(view.pid).socket.assigns.batch_files == %{}
  end

  test "a large batch shows 500 claims, flagged first, and says how many there are", %{conn: conn} do
    low = for i <- 1..500, do: {"low_#{i}.json", {"evaluated", report("LowRisk", 0)}}
    high = for i <- 1..3, do: {"high_#{i}.json", {"evaluated", report("HighRisk", 1)}}
    batch = insert_batch(low ++ high)
    view = open_history(conn)

    html = expand(view, batch)
    assert html =~ "Showing 500 of 503 claims, flagged claims first."
    assert html =~ "high_3"

    # The filter runs in the database: all three high-risk claims, no note.
    html = render_click(view, "filter_batch_risk", %{"level" => "HighRisk"})
    assert html =~ "high_1" and html =~ "high_2" and html =~ "high_3"
    refute html =~ "low_1.json"
    refute html =~ "Showing"
  end

  test "Clean leaves out claims with unchecked rules and claims never evaluated", %{conn: conn} do
    batch =
      insert_batch([
        {"truly_clean.json", {"evaluated", report("LowRisk", 0)}},
        {"undecided.json", {"evaluated", report("LowRisk", 0, true)}},
        {"never_evaluated.json", {"translated", nil}},
        {"timed_out.json", {"not_assessed", nil}}
      ])

    view = open_history(conn)
    expand(view, batch)
    html = render_click(view, "filter_batch_risk", %{"level" => "Clean"})

    assert html =~ "truly_clean"
    refute html =~ "undecided"
    refute html =~ "never_evaluated"
    refute html =~ "timed_out"

    html = render_click(view, "filter_batch_risk", %{"level" => "NotAssessed"})
    assert html =~ "timed_out"
    refute html =~ "truly_clean"
  end
end
