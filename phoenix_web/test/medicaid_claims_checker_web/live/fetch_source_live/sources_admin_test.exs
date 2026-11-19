defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.SourcesAdminTest do
  # Fetch sources and schedules are managed by administrators only; a zip
  # that would unpack too large is refused before it is unpacked.
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures, Ingestion, Repo}
  alias MedicaidClaimsChecker.Ingestion.FetchSource

  @source %{"name" => "Daily", "uri" => "/tmp/claims/", "type" => "local"}

  describe "a user who is not an administrator" do
    setup %{conn: conn}, do: %{conn: log_in_user(conn, AccountsFixtures.user_fixture())}

    test "sees no source controls, only a line saying who manages them", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Fetch sources and schedules are managed by an administrator."
      refute html =~ "toggle_add_source_form"
    end

    test "can't add or change a source by sending the events", %{conn: conn} do
      {:ok, source} =
        Ingestion.create_fetch_source(%{name: "Existing", uri: "/tmp/a/", source_type: "local"})

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "save_source", %{"source" => @source})
      assert html =~ "Only an administrator can change fetch sources and schedules."

      render_click(view, "delete_source", %{"id" => "#{source.id}"})
      render_click(view, "save_schedule", %{"schedule" => %{"cron" => "0 * * * *"}})

      assert [%{name: "Existing"}] = Repo.all(FetchSource)
      assert Repo.aggregate(Ingestion.FetchSchedule, :count) == 0
    end

    test "a zip that would unpack too large is refused and named", %{conn: conn} do
      {:ok, {_, bomb}} =
        :zip.create(~c"big.zip", [{~c"claims.x12", :binary.copy(<<0>>, 2_000_000)}], [:memory])

      previous = Application.get_env(:medicaid_claims_checker, :remote_fetcher)

      Application.put_env(
        :medicaid_claims_checker,
        :remote_fetcher,
        Keyword.put(previous || [], :max_unzipped_bytes, 1_000_000)
      )

      on_exit(fn -> Application.put_env(:medicaid_claims_checker, :remote_fetcher, previous) end)

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> file_input("#manual-upload-form", :manual_files, [
        %{name: "big.zip", content: bomb, type: "application/zip"}
      ])
      |> render_upload("big.zip")

      html = view |> form("#manual-upload-form") |> render_submit()

      assert html =~ "No processable claims found"

      assert html =~
               "Not unpacked: big.zip: it would unpack to 2.0 MB, more than the 1.0 MB allowed."
    end
  end

  describe "an administrator" do
    setup %{conn: conn} do
      {:ok, admin} = AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)
      %{conn: log_in_user(conn, admin)}
    end

    test "adds a source and a schedule; a cron the scheduler can't run is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "save_source", %{"source" => @source})
      assert [source] = Repo.all(FetchSource)

      render_click(view, "toggle_expand_source", %{"id" => "#{source.id}"})
      render_click(view, "show_add_schedule", %{"source-id" => "#{source.id}"})
      html = render_click(view, "save_schedule", %{"schedule" => %{"cron" => "99 * * * *"}})
      assert html =~ "is not valid"
      assert Repo.aggregate(Ingestion.FetchSchedule, :count) == 0

      render_click(view, "save_schedule", %{"schedule" => %{"interval" => "900"}})
      assert Repo.aggregate(Ingestion.FetchSchedule, :count) == 1
    end
  end
end
