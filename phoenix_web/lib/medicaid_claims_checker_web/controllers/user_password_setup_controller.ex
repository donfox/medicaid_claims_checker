defmodule MedicaidClaimsCheckerWeb.UserPasswordSetupController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsChecker.Accounts.User
  alias MedicaidClaimsCheckerWeb.UserAuth

  # The page an admin's "Set your password" email links to.
  def edit(conn, %{"token" => token}) do
    if user = Accounts.get_user_by_password_setup_token(token) do
      form =
        user
        |> User.password_changeset(%{}, hash_password: false)
        |> Phoenix.Component.to_form(as: :user)

      render(conn, :edit, user: user, token: token, form: form)
    else
      invalid_link(conn)
    end
  end

  def update(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.set_password_with_setup_token(token, user_params) do
      {:ok, {user, _expired_tokens}} ->
        conn
        |> put_flash(:info, "Password set. Welcome, #{User.full_name(user)}!")
        |> UserAuth.log_in_user(user, user_params)

      {:error, %Ecto.Changeset{} = changeset} ->
        user = Accounts.get_user_by_password_setup_token(token)

        render(conn, :edit,
          user: user,
          token: token,
          form: Phoenix.Component.to_form(changeset, as: :user)
        )

      {:error, :not_found} ->
        invalid_link(conn)
    end
  end

  defp invalid_link(conn) do
    conn
    |> put_flash(
      :error,
      "This password link is invalid, has expired, or was already used. Ask an administrator to send a new one."
    )
    |> redirect(to: ~p"/users/log-in")
  end
end
