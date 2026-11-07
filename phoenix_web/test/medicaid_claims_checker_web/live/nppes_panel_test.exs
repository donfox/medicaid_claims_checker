defmodule MedicaidClaimsCheckerWeb.NppesPanelTest do
  @moduledoc """
  The NPPES registry controls live on the Admin page; Claims Intake shows a
  read-only status line. None of these tests starts a refresh, which would
  download the real registry.

  Saving settings also notifies the app-wide `RefreshWorker`, which reads the
  database from its own process. The tests let it use this test's sandbox
  connection and wait for it to finish, so they run one at a time.
  """
  use MedicaidClaimsCheckerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures, Nppes, Repo}
  alias MedicaidClaimsChecker.Nppes.RefreshWorker

  defp allow_refresh_worker(_context) do
    worker = Process.whereis(RefreshWorker)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)
    %{worker: worker}
  end

  # Waits until the worker has handled the config change sent to it.
  defp wait_for(worker), do: :sys.get_state(worker)

  defp log_in(conn, admin?) do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Accounts.set_user_admin(user, admin?)
    log_in_user(conn, user)
  end

  describe "Admin page" do
    setup %{conn: conn}, do: %{conn: log_in(conn, true)}
    setup :allow_refresh_worker

    test "shows the registry panel with its controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#nppes-panel", "NPPES Provider Registry")
      assert has_element?(view, "#nppes-refresh-now")
      assert has_element?(view, "#nppes-auto-refresh-toggle")
      assert has_element?(view, "#nppes-config-form")
    end

    test "saves the refresh interval and download URL", %{conn: conn, worker: worker} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      url = "https://download.cms.gov/nppes/NPPES_Data_Dissemination_Test.zip"

      view
      |> form("#nppes-config-form", %{
        "nppes" => %{"interval_seconds" => "86400", "download_url" => url}
      })
      |> render_submit()

      wait_for(worker)
      assert has_element?(view, "[role=alert]", "NPPES settings saved.")
      config = Nppes.get_refresh_config()
      assert config.interval_seconds == 86_400
      assert config.download_url == url
    end

    test "turns auto-refresh on and off", %{conn: conn, worker: worker} do
      before = Nppes.get_refresh_config().auto_refresh
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#nppes-auto-refresh-toggle") |> render_click()
      wait_for(worker)

      assert Nppes.get_refresh_config().auto_refresh == !before
    end

    # Status messages are sent straight to the page, as the worker's
    # broadcasts would be, so no real refresh runs.
    test "a new refresh or its result clears an earlier notice", %{conn: conn, worker: worker} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      for status <- [%{status: :running, started_at: DateTime.utc_now()}, %{status: :completed}] do
        view |> form("#nppes-config-form") |> render_submit()
        wait_for(worker)
        assert has_element?(view, "[role=alert]", "NPPES settings saved.")

        send(view.pid, {:nppes_status, status})
        refute has_element?(view, "[role=alert]", "NPPES settings saved.")
      end
    end

    test "the cancelled status keeps the cancel notice", %{conn: conn, worker: worker} do
      {:ok, view, _html} = live(conn, ~p"/admin")
      view |> form("#nppes-config-form") |> render_submit()
      wait_for(worker)

      send(view.pid, {:nppes_status, %{status: :cancelled}})
      assert has_element?(view, "[role=alert]", "NPPES settings saved.")
    end
  end

  test "time_ago uses the singular for one hour or one day" do
    alias MedicaidClaimsCheckerWeb.AdminLive.NppesPanel
    ago = &DateTime.add(DateTime.utc_now(), -&1, :second)

    assert NppesPanel.time_ago(ago.(3_700)) == "1 hour ago"
    assert NppesPanel.time_ago(ago.(7_300)) == "2 hours ago"
    assert NppesPanel.time_ago(ago.(86_500)) == "1 day ago"
    assert NppesPanel.time_ago(ago.(3 * 86_400 + 5)) == "3 days ago"
  end

  describe "cancel notice" do
    alias MedicaidClaimsCheckerWeb.AdminLive.NppesPanel

    test "says the registry is unchanged when no rows were imported" do
      assert NppesPanel.cancel_message(0) =~ "unchanged"
    end

    test "says how many rows kept the newer details once the import has started" do
      message = NppesPanel.cancel_message(1_200_000)

      assert message =~ "after 1,200,000 rows"
      assert message =~ "no providers were removed"
      refute message =~ "unchanged"
    end
  end

  describe "non-admin users" do
    setup %{conn: conn}, do: %{conn: log_in(conn, false)}

    test "cannot open the Admin page", %{conn: conn} do
      assert {:error, {:redirect, _}} = live(conn, ~p"/admin")
    end

    test "see the read-only status on Claims Intake, with no controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#nppes-summary", "NPPES provider registry")
      refute has_element?(view, "#nppes-panel")
      refute has_element?(view, "#nppes-refresh-now")
      refute has_element?(view, "#nppes-summary a[href='/admin']")
    end
  end

  test "admins get a link from the Claims Intake status to Admin", %{conn: conn} do
    {:ok, view, _html} = live(log_in(conn, true), ~p"/")

    assert has_element?(view, "#nppes-summary a[href='/admin']", "Manage on Admin")
    refute has_element?(view, "#nppes-panel")
  end
end
