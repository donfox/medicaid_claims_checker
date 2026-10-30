defmodule MedicaidClaimsChecker.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias MedicaidClaimsChecker.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # An admin hands the password-setup link over, so it must outlast a weekend.
  @password_setup_validity_in_days 3
  @session_validity_in_days 14

  schema "users_tokens" do
    field(:token, :binary)
    field(:context, :string)
    field(:sent_to, :string)
    field(:authenticated_at, :utc_datetime)
    belongs_to(:user, MedicaidClaimsChecker.Accounts.User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from(token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}
      )

    {:ok, query}
  end

  @doc """
  Builds a token for a link, and its hash.

  The non-hashed token goes in the link while the hashed part is stored in
  the database, so anyone with read-only access to the database cannot use
  it. The token records the user's email when it was made; if the email
  changes, the link stops working.
  """
  def build_link_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the password-setup token is valid and returns its underlying
  lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The token is valid if it matches its hashed counterpart in the database,
  was sent to the user's current email, and is less than
  #{@password_setup_validity_in_days} days old. Its context is always
  "password_setup".
  """
  def verify_password_setup_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from(token in by_token_and_context_query(hashed_token, "password_setup"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@password_setup_validity_in_days, "day"),
            where: token.sent_to == user.email,
            select: {user, token}
          )

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc "How many days a password-setup link stays valid."
  def password_setup_validity_in_days, do: @password_setup_validity_in_days

  defp by_token_and_context_query(token, context) do
    from(UserToken, where: [token: ^token, context: ^context])
  end
end
