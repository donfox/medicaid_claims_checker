defmodule MedicaidClaimsCheckerWeb.UserSettingsControllerTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  alias MedicaidClaimsChecker.Accounts
  import MedicaidClaimsChecker.AccountsFixtures

  setup :register_and_log_in_user

  describe "GET /users/settings" do
    test "renders settings page", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ "Settings"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."
    end
  end

  describe "PUT /users/settings (change password form)" do
    test "updates the user password and resets tokens", %{conn: conn, user: user} do
      new_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "does not update password on invalid data", %{conn: conn} do
      old_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      response = html_response(old_password_conn, 200)
      assert response =~ "Settings"
      assert response =~ "should be at least 12 character(s)"
      assert response =~ "does not match password"

      assert get_session(old_password_conn, :user_token) == get_session(conn, :user_token)
    end
  end

  describe "PUT /users/settings (change email form)" do
    test "changes the user email at once", %{conn: conn, user: user} do
      email = unique_user_email()

      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => email}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Email changed successfully"
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)
    end

    test "does not update email on invalid data", %{conn: conn} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "must have the @ sign and no spaces"
    end
  end

  describe "PUT /users/settings (profile form)" do
    test "changes the name and username", %{conn: conn, user: user} do
      username = unique_username()

      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_profile",
          "user" => %{"first_name" => "Ada", "last_name" => "Lovelace", "username" => username}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Profile updated successfully"

      updated = Accounts.get_user!(user.id)

      assert {updated.first_name, updated.last_name, updated.username} ==
               {"Ada", "Lovelace", username}
    end

    test "shows the user's name in the top bar", %{conn: conn, user: user} do
      html = conn |> get(~p"/users/settings") |> html_response(200)

      assert html =~ ~s(id="current-user-name")
      assert html =~ Accounts.User.full_name(user)
    end

    test "does not update the profile on invalid data", %{conn: conn, user: user} do
      other = user_fixture()

      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_profile",
          "user" => %{"first_name" => "", "last_name" => "X", "username" => other.username}
        })

      response = html_response(conn, 200)
      assert response =~ "can&#39;t be blank"
      assert response =~ "has already been taken"
      assert Accounts.get_user!(user.id).username == user.username
    end
  end

  describe "PUT /users/settings (log out other sessions)" do
    test "ends the other sessions and keeps this one", %{conn: conn, user: user} do
      other_token = Accounts.generate_user_session_token(user)
      this_token = get_session(conn, :user_token)

      conn = put(conn, ~p"/users/settings", %{"action" => "log_out_other_sessions"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Logged out of 1 other session."
      refute Accounts.get_user_by_session_token(other_token)
      assert Accounts.get_user_by_session_token(this_token)
    end

    test "does not touch another user's sessions", %{conn: conn} do
      someone_else = user_fixture()
      their_token = Accounts.generate_user_session_token(someone_else)

      conn = put(conn, ~p"/users/settings", %{"action" => "log_out_other_sessions"})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "You were not logged in anywhere else."

      assert Accounts.get_user_by_session_token(their_token)
    end
  end
end
