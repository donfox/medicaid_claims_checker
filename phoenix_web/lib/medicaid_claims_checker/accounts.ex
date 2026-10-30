defmodule MedicaidClaimsChecker.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias MedicaidClaimsChecker.Repo

  alias MedicaidClaimsChecker.Accounts.{User, UserToken, AppSettings}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  def get_user_by_login_and_password(login, password)
      when is_binary(login) and is_binary(password) do
    user =
      if String.contains?(login, "@") do
        Repo.get_by(User, email: login)
      else
        Repo.get_by(User, username: login)
      end

    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def list_users do
    Repo.all(from(u in User, order_by: [asc: u.inserted_at]))
  end

  def set_user_active(user, active) when is_boolean(active) do
    user
    |> Ecto.Changeset.change(active: active)
    |> Repo.update()
  end

  def set_user_admin(user, is_admin) when is_boolean(is_admin) do
    user
    |> Ecto.Changeset.change(is_admin: is_admin)
    |> Repo.update()
  end

  @doc """
  Sets (or with `nil`, resets) the time before which batches are hidden
  from the user's Jobs History display. Display-only: no batch or claim
  record is changed.
  """
  def set_history_cleared_at(user, cleared_at) do
    user
    |> Ecto.Changeset.change(history_cleared_at: cleared_at)
    |> Repo.update()
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def register_admin(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:is_admin, true)
    |> Repo.insert()
  end

  def change_user_registration(user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  def registration_open? do
    case Repo.get(AppSettings, "singleton") do
      %AppSettings{registration_open: open} -> open
      nil -> false
    end
  end

  def set_registration_open(open) when is_boolean(open) do
    case Repo.get(AppSettings, "singleton") do
      nil ->
        %AppSettings{key: "singleton"}
        |> AppSettings.changeset(%{registration_open: open})
        |> Repo.insert()

      settings ->
        settings
        |> AppSettings.changeset(%{registration_open: open})
        |> Repo.update()
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `MedicaidClaimsChecker.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Changes the user's email address. The settings page asks for a recent
  log-in first (sudo mode); there is no confirmation email.
  """
  def update_user_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `MedicaidClaimsChecker.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Creates a one-time link for a user to set a new password. An admin
  creates it on the Admin page and gives it to the user; the app sends no
  email. It lets in accounts made before password registration, which have
  no password, and users who have forgotten theirs.

  Returns `{:ok, url}`.
  """
  def create_password_setup_link(%User{} = user, setup_url_fun)
      when is_function(setup_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_link_token(user, "password_setup")
    Repo.insert!(user_token)
    {:ok, setup_url_fun.(encoded_token)}
  end

  @doc """
  Gets the user a valid password-setup token belongs to, or `nil`.
  """
  def get_user_by_password_setup_token(token) do
    with {:ok, query} <- UserToken.verify_password_setup_token_query(token),
         {%User{} = user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Sets the password of the user a password-setup token belongs to, and
  confirms the account: the admin gave the link to that person. Every token
  the user has is deleted, so the link works once and any other log-in
  session ends.

  Returns `{:ok, {user, expired_tokens}}`, `{:error, changeset}` for an
  invalid password, or `{:error, :not_found}` when the link is invalid or
  expired.
  """
  def set_password_with_setup_token(token, attrs) do
    case get_user_by_password_setup_token(token) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> User.password_changeset(attrs)
        |> Ecto.Changeset.put_change(
          :confirmed_at,
          user.confirmed_at || DateTime.utc_now(:second)
        )
        |> update_user_and_delete_all_tokens()
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
