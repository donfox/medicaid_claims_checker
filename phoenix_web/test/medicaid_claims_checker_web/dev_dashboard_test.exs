defmodule MedicaidClaimsCheckerWeb.DevDashboardTest do
  # The development-only LiveDashboard is for logged-in admins only.
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures}

  test "without logging in, the dashboard sends you to the log-in page", %{conn: conn} do
    conn = get(conn, "/dev/dashboard/home")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "a user who is not an admin is turned away", %{conn: conn} do
    conn = conn |> log_in_user(AccountsFixtures.user_fixture()) |> get("/dev/dashboard/home")
    assert redirected_to(conn) == ~p"/"
  end

  test "an admin can open it", %{conn: conn} do
    {:ok, admin} = AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)
    {:ok, _view, html} = conn |> log_in_user(admin) |> live("/dev/dashboard/home")
    assert html =~ "Dashboard"
  end

  # Admin links to this address so the browser's Back button works: it opens
  # without forwarding, while the bare /dev/dashboard forwards to it.
  test "/dev/dashboard/home opens without forwarding; the bare path forwards", %{conn: conn} do
    {:ok, admin} = AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)
    conn = log_in_user(conn, admin)
    assert {:ok, _view, _html} = live(conn, "/dev/dashboard/home")
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/dev/dashboard")
    assert to == "/dev/dashboard/home"
  end
end
