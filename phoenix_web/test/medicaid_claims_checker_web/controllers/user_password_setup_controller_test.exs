defmodule MedicaidClaimsCheckerWeb.UserPasswordSetupControllerTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import MedicaidClaimsChecker.AccountsFixtures

  alias MedicaidClaimsChecker.Accounts

  setup do
    user = unconfirmed_user_fixture()

    %{user: user, token: password_setup_token(user)}
  end

  defp passwords(password, confirmation \\ nil) do
    %{"user" => %{"password" => password, "password_confirmation" => confirmation || password}}
  end

  describe "GET /users/set-password/:token" do
    test "shows the form for a valid link", %{conn: conn, user: user, token: token} do
      response = conn |> get(~p"/users/set-password/#{token}") |> html_response(200)
      assert response =~ "Set your password"
      assert response =~ user.email
    end

    test "sends an invalid link to the log-in page", %{conn: conn} do
      conn = get(conn, ~p"/users/set-password/oops")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "invalid, has expired, or was already used"
    end
  end

  describe "PUT /users/set-password/:token" do
    test "sets the password and logs the user in", %{conn: conn, user: user, token: token} do
      conn = put(conn, ~p"/users/set-password/#{token}", passwords(valid_user_password()))

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password set. Welcome"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "resets the password of a user who has forgotten theirs", %{conn: conn} do
      user = user_fixture()
      token = password_setup_token(user)

      conn = put(conn, ~p"/users/set-password/#{token}", passwords("a brand new password"))

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_email_and_password(user.email, "a brand new password")
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "shows errors for an invalid password", %{conn: conn, token: token} do
      response =
        conn
        |> put(~p"/users/set-password/#{token}", passwords("short", "other"))
        |> html_response(200)

      assert response =~ "should be at least 12 character"
      assert response =~ "does not match password"
    end

    test "refuses a link that was already used", %{conn: conn, token: token} do
      put(conn, ~p"/users/set-password/#{token}", passwords(valid_user_password()))

      conn = put(build_conn(), ~p"/users/set-password/#{token}", passwords("another password!"))
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end
  end
end
