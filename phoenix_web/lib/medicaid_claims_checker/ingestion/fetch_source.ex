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

  @valid_source_types ~w(sftp local http databricks)

  def changeset(fetch_source, attrs) do
    fetch_source
    |> cast(attrs, [:name, :uri, :source_type, :enabled, :credentials])
    |> validate_required([:name, :uri, :source_type])
    |> validate_inclusion(:source_type, @valid_source_types)
    |> unique_constraint(:name)
  end
end
