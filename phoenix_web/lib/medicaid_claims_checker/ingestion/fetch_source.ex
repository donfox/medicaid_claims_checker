defmodule MedicaidClaimsChecker.Ingestion.FetchSource do
  use Ecto.Schema
  import Ecto.Changeset

  schema "fetch_sources" do
    field :name, :string
    field :uri, :string
    field :source_type, :string
    field :enabled, :boolean, default: true
    field :credentials, MedicaidClaimsChecker.Encrypted.Map

    has_many :fetch_schedules, MedicaidClaimsChecker.Ingestion.FetchSchedule

    timestamps(type: :utc_datetime)
  end

  @valid_source_types ~w(sftp local http)

  def changeset(fetch_source, attrs) do
    fetch_source
    |> cast(attrs, [:name, :uri, :source_type, :enabled, :credentials])
    |> validate_required([:name, :uri, :source_type])
    |> validate_inclusion(:source_type, @valid_source_types)
    |> validate_no_password_in_uri()
    |> unique_constraint(:name)
  end

  # The URI is stored unencrypted and written to the log on every fetch, so a
  # password in it (sftp://user:secret@host) would leak. The fetcher never
  # used it as a password anyway. A user name alone (sftp://user@host) is fine.
  defp validate_no_password_in_uri(changeset) do
    validate_change(changeset, :uri, fn :uri, uri ->
      case URI.parse(uri) do
        %URI{userinfo: info} when is_binary(info) ->
          if String.contains?(info, ":"),
            do: [uri: "must not contain a password; enter it in the Password field"],
            else: []

        _ ->
          []
      end
    end)
  end
end
