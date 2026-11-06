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
end
