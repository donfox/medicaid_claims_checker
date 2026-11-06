defmodule MedicaidClaimsCheckerWeb.UserSettingsController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsCheckerWeb.UserAuth

  import MedicaidClaimsCheckerWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  plug :assign_email_and_password_changesets

  def edit(conn, _params) do
    render(conn, :edit)
  end

  def update(conn, %{"action" => "update_profile"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Profile updated successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, changeset} ->
        render(conn, :edit, profile_changeset: changeset)
    end
  end

  def update(conn, %{"action" => "log_out_other_sessions"}) do
    user = conn.assigns.current_scope.user
    count = Accounts.delete_other_user_session_tokens(user, get_session(conn, :user_token))

    message =
      case count do
        0 -> "You were not logged in anywhere else."
        1 -> "Logged out of 1 other session."
        n -> "Logged out of #{n} other sessions."
      end

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/users/settings")
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_email(user, user_params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, changeset} ->
        render(conn, :edit, email_changeset: changeset)
    end
  end

  def update(conn, %{"action" => "update_password"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        conn
        |> put_flash(:info, "Password updated successfully.")
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :edit, password_changeset: changeset)
    end
  end

  defp assign_email_and_password_changesets(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:profile_changeset, Accounts.change_user_profile(user))
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:password_changeset, Accounts.change_user_password(user))
  end
end
