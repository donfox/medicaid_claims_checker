defmodule MedicaidClaimsChecker.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `MedicaidClaimsChecker.Accounts` context.
  """

  import Ecto.Query

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsChecker.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def unique_username, do: "user#{System.unique_integer([:positive])}"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password(),
      username: unique_username(),
      first_name: "Test",
      last_name: "User"
    })
  end

  # A registered user: registration sets a password and confirms the account.
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  # A user with no password and no confirmation, which registration no longer
  # creates (older accounts can still be in this state). An admin gives them
  # a password-setup link.
  def unconfirmed_user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)

    %Accounts.User{}
    |> Ecto.Changeset.change(Map.take(attrs, [:email, :username, :first_name, :last_name]))
    |> MedicaidClaimsChecker.Repo.insert!()
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  # The token of a new password-setup link for a user with no password.
  def password_setup_token(user) do
    {:ok, token} = Accounts.create_password_setup_link(user, & &1)
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    MedicaidClaimsChecker.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    MedicaidClaimsChecker.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
