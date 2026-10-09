defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.JobsHistoryTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims.{Batch, EdiFile}
  alias MedicaidClaimsChecker.Repo

  defp insert_batch(name, inserted_at) do
    batch =
      Repo.insert!(%Batch{
        batch_id: Ecto.UUID.generate(),
        batch_name: name,
        source: "manual_upload",
        file_count: 1,
        status: "completed",
        inserted_at: inserted_at,
        updated_at: inserted_at
      })

    Repo.insert!(%EdiFile{batch_id: batch.id, filename: "#{name}.json", file_path: "#{name}.json", status: "evaluated"})
    batch
  end

  defp seconds_ago(s), do: DateTime.add(DateTime.utc_now(:second), -s)

  setup %{conn: conn} do
    # Registration only; avoids the login-email path (no mail in tests).
    user = AccountsFixtures.unconfirmed_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp open_history(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[aria-controls=batch-history-panel]") |> render_click()
    view
  end

  test "clearing the display hides batches but deletes no records", %{conn: conn, user: user} do
    insert_batch("Older batch A", seconds_ago(120))
    insert_batch("Older batch B", seconds_ago(60))
    view = open_history(conn)
    assert render(view) =~ "Older batch A"

    html = view |> element("#clear-history-display") |> render_click()

    refute html =~ "Older batch A"
    assert html =~ "Display cleared"
    assert html =~ "(2 hidden)"
    assert Repo.aggregate(Batch, :count) == 2
    assert Repo.aggregate(EdiFile, :count) == 2
    assert Accounts.get_user!(user.id).history_cleared_at

    html = view |> element("#toggle-show-all-history") |> render_click()
    assert html =~ "Older batch A"
    assert html =~ "Older batch B"
  end

  test "batches received after clearing are shown", %{conn: conn, user: user} do
    insert_batch("Before clear", seconds_ago(120))
    {:ok, _} = Accounts.set_history_cleared_at(user, seconds_ago(60))
    insert_batch("After clear", seconds_ago(30))

    html = conn |> open_history() |> render()

    assert html =~ "After clear"
    refute html =~ "Before clear"
  end

  test "older batches are reachable through paging", %{conn: conn} do
    for i <- 1..25, do: insert_batch("Batch #{String.pad_leading("#{i}", 2, "0")}", seconds_ago(1000 - i))
    view = open_history(conn)

    html = render(view)
    assert html =~ "Page 1 of 2"
    assert html =~ "Batch 25"
    refute html =~ "Batch 05"

    html = view |> element("#history-pagination button", "Older") |> render_click()
    assert html =~ "Page 2 of 2"
    assert html =~ "Batch 05"
    refute html =~ "Batch 25"
  end
end
