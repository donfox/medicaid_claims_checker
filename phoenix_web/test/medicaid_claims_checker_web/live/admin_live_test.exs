defmodule MedicaidClaimsCheckerWeb.AdminLiveTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures}

  setup %{conn: conn} do
    {:ok, admin} = AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "the page shows its messages", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    render_click(view, "toggle_active", %{"id" => "#{admin.id}"})

    assert has_element?(view, "[role=alert]", "You cannot deactivate your own account.")
  end

  test "the top bar links back to Claims Intake", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")

    assert html =~ ~s(id="app-home-link")
    assert html =~ ~s(href="/")
  end

  test "on Claims Intake the app name is plain text, not a link to itself", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="app-name")
    refute html =~ ~s(id="app-home-link")
  end

  test "Business Rules is titled to match its link, and only the top bar links home",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/rules")

    assert has_element?(view, "#rules-title", "Business Rules")
    # The top bar is in the root layout, outside the LiveView, so check the page HTML.
    assert html =~ ~s(id="app-home-link")
    refute has_element?(view, "#claims-intake-link")
  end

  test "an ML Model with no scoring service shows as Not connected, not active",
       %{conn: conn} do
    {:ok, entry} =
      MedicaidClaimsChecker.Claims.create_catalogue_entry(%{
        name: "SomeRiskModel",
        description: "",
        entry_type: "ML Model",
        status: "Not connected"
      })

    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#not-connected-#{entry.id}", "Not connected")
    assert render(view) =~ "1 total, not connected"
  end

  test "a Default Rule that isn't implemented shows Not connected, not Always On",
       %{conn: conn} do
    {:ok, waiting} =
      MedicaidClaimsChecker.Claims.create_catalogue_entry(%{
        name: "SomeTableRule",
        description: "Needs a table not loaded yet",
        entry_type: "Default Rule",
        status: "Not connected",
        db_access: true
      })

    {:ok, running} =
      MedicaidClaimsChecker.Claims.create_catalogue_entry(%{
        name: "SomeRunningRule",
        description: "",
        entry_type: "Default Rule",
        status: "Active"
      })

    {:ok, view, _html} = live(conn, ~p"/rules")

    assert has_element?(view, "#not-connected-#{waiting.id}", "Not connected")
    refute has_element?(view, "#catalog-entry-#{waiting.id}", "Always On")
    assert has_element?(view, "#catalog-entry-#{running.id}", "Always On")
    assert render(view) =~ "2 total, 1 not connected"

    render_click(view, "select_catalog_rule", %{"id" => "#{waiting.id}"})
    assert render(view) =~ "Not connected: not implemented yet, so it is not run on claims."
  end

  describe "Create password link" do
    test "is offered for every user, with or without a password", %{conn: conn} do
      passwordless = AccountsFixtures.unconfirmed_user_fixture()
      with_password = AccountsFixtures.user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#create-password-link-#{passwordless.id}")
      assert has_element?(view, "#create-password-link-#{with_password.id}")
    end

    test "shows a working set-password link for the admin to give the user", %{conn: conn} do
      user = AccountsFixtures.unconfirmed_user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#create-password-link-#{user.id}") |> render_click()

      assert has_element?(view, "#password-link", user.email)

      [link] =
        view
        |> element("#password-link input")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("value")

      assert "/users/set-password/" <> token = URI.parse(link).path
      assert Accounts.get_user_by_password_setup_token(token).id == user.id
    end

    test "is disabled for an inactive user", %{conn: conn} do
      user = AccountsFixtures.unconfirmed_user_fixture()
      {:ok, _} = Accounts.set_user_active(user, false)
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#create-password-link-#{user.id}[disabled]")
    end
  end

  describe "rights changed on the Admin page apply to the user's open pages" do
    alias MedicaidClaimsChecker.Repo
    alias MedicaidClaimsCheckerWeb.UserAuth

    test "deactivating ends the user's sessions and disconnects their pages", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)
      MedicaidClaimsCheckerWeb.Endpoint.subscribe(UserAuth.user_session_topic(token))

      {:ok, view, _html} = live(conn, ~p"/admin")
      render_click(view, "toggle_active", %{"id" => "#{user.id}"})

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute Accounts.get_user_by_session_token(token)
      refute Repo.reload!(user).active
    end

    test "removing admin rights disconnects their pages; their open page can't act", %{conn: conn} do
      {:ok, other} = AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)
      bystander = AccountsFixtures.user_fixture()
      other_conn = log_in_user(build_conn(), other)
      {:ok, other_view, _} = live(other_conn, ~p"/admin")

      token = Accounts.session_tokens(other) |> hd()
      MedicaidClaimsCheckerWeb.Endpoint.subscribe(UserAuth.user_session_topic(token))

      {:ok, view, _html} = live(conn, ~p"/admin")
      render_click(view, "toggle_admin", %{"id" => "#{other.id}"})
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      # Even before the page reconnects, its clicks are checked afresh.
      html = render_click(other_view, "toggle_admin", %{"id" => "#{bystander.id}"})
      assert html =~ "Invalid request."
      refute Repo.reload!(bystander).is_admin
    end
  end

  test "in development the System section links to the system monitor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    assert view |> element("#system-monitor a[href='/dev/dashboard']") |> has_element?()
    # Same tab, so the browser's Back button returns to Admin.
    refute view |> element("#system-monitor a[target]") |> has_element?()
  end

  describe "User Registration" do
    test "sits in the Users section, above the accounts table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      [_, users_section] = String.split(html, ">Users</h2>", parts: 2)
      [before_table, _] = String.split(users_section, "<table", parts: 2)

      assert before_table =~ ~s(id="registration")
      refute html |> String.split(">Users</h2>") |> hd() =~ ~s(id="registration")
    end

    test "says what each state means, and the switch changes it", %{conn: conn} do
      # A new database starts closed.
      {:ok, view, _html} = live(conn, ~p"/admin")
      assert has_element?(view, "#registration", "nobody can create an account")
      assert has_element?(view, "#registration button", "Closed — click to open")

      render_click(view, "toggle_registration", %{})
      assert Accounts.registration_open?()
      assert has_element?(view, "#registration", "anyone who can reach the app can create an account")
      assert has_element?(view, "#registration button", "Open — click to close")

      render_click(view, "toggle_registration", %{})
      refute Accounts.registration_open?()
      assert has_element?(view, "#registration", "nobody can create an account")
    end
  end
end
