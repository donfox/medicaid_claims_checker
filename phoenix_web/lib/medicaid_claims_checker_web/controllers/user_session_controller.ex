defmodule MedicaidClaimsCheckerWeb.UserSessionController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsChecker.Accounts.User
  alias MedicaidClaimsCheckerWeb.UserAuth

  def new(conn, _params) do
    email = get_in(conn.assigns, [:current_scope, Access.key(:user), Access.key(:email)])
    form = Phoenix.Component.to_form(%{"email" => email}, as: "user")

    render(conn, :new, form: form)
  end

  # email or username + password login
  def create(conn, %{"user" => %{"email" => login, "password" => password} = user_params}) do
    if user = Accounts.get_user_by_login_and_password(login, password) do
      conn
      |> put_flash(:info, "Welcome back, #{User.full_name(user)}")
      |> UserAuth.log_in_user(user, user_params)
    else
      form = Phoenix.Component.to_form(user_params, as: "user")

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      # The app sends no email: a user with no password, or who has forgotten
      # it, gets a password link from an admin.
      conn
      |> put_flash(
        :error,
        "Invalid email or password. If you don't have a password yet, or have forgotten it, ask an administrator."
      )
      |> render(:new, form: form)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
