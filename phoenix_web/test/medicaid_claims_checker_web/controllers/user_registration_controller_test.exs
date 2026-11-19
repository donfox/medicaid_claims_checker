defmodule MedicaidClaimsCheckerWeb.UserRegistrationControllerTest do
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import MedicaidClaimsChecker.AccountsFixtures

  alias MedicaidClaimsChecker.Accounts

  # A new database starts with registration closed; these tests open it.
  setup do
    {:ok, _} = Accounts.set_registration_open(true)
    :ok
  end

  describe "GET /users/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ ~p"/users/log-in"
      assert response =~ ~p"/users/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/users/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /users/register" do
    @tag :capture_log
    test "creates a confirmed account and logs the user in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => valid_user_attributes(email: email)
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert conn.assigns.flash["info"] == "Welcome, Test User! Your account has been created."
      assert MedicaidClaimsChecker.Accounts.get_user_by_email(email).confirmed_at
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ "must have the @ sign and no spaces"
    end
  end

  describe "while registration is closed" do
    setup do
      {:ok, _} = Accounts.set_registration_open(false)
      :ok
    end

    test "the registration page sends visitors to log in", %{conn: conn} do
      conn = get(conn, ~p"/users/register")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert conn.assigns.flash["error"] == "Registration is currently closed."
    end

    test "a registration posted anyway creates no account", %{conn: conn} do
      email = unique_user_email()
      conn = post(conn, ~p"/users/register", %{"user" => valid_user_attributes(email: email)})

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_email(email)
    end
  end
end
