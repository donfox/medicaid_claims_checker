defmodule MedicaidClaimsCheckerWeb.UserRegistrationController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsChecker.Accounts.User
  alias MedicaidClaimsCheckerWeb.UserAuth

  def new(conn, _params) do
    if Accounts.registration_open?() do
      changeset = Accounts.change_user_registration(%User{}) |> Phoenix.Component.to_form()
      render(conn, :new, changeset: changeset)
    else
      conn
      |> put_flash(:error, "Registration is currently closed.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def create(conn, %{"user" => user_params}) do
    unless Accounts.registration_open?() do
      conn
      |> put_flash(:error, "Registration is currently closed.")
      |> redirect(to: ~p"/users/log-in")
    else
      case Accounts.register_user(user_params) do
        {:ok, user} ->
          conn
          |> put_flash(:info, "Welcome, #{User.full_name(user)}! Your account has been created.")
          |> UserAuth.log_in_user(user, user_params)

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :new, changeset: Phoenix.Component.to_form(changeset))
      end
    end
  end
end
