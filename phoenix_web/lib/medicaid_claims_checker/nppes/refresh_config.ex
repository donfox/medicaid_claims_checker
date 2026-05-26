defmodule MedicaidClaimsChecker.Nppes.RefreshConfig do
  @moduledoc """
  Single-row configuration for automated NPPES provider data refresh.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias MedicaidClaimsChecker.Repo

  @default_url "https://download.cms.gov/nppes/NPPES_Data_Dissemination_May_2026_V2.zip"

  schema "nppes_refresh_config" do
    field :auto_refresh, :boolean, default: true
    field :interval_seconds, :integer, default: 604_800
    field :download_url, :string, default: @default_url
    field :last_refresh_at, :utc_datetime
    field :last_row_count, :integer, default: 0
    field :last_status, :string, default: "never"
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :auto_refresh,
    :interval_seconds,
    :download_url,
    :last_refresh_at,
    :last_row_count,
    :last_status,
    :last_error
  ]

  def changeset(config, attrs) do
    config
    |> cast(attrs, @cast_fields)
    |> validate_required([:download_url, :interval_seconds])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 3600)
    |> validate_inclusion(:last_status, ~w(never running completed failed))
  end

  @doc """
  Returns the single config row, creating a default one if none exists.
  """
  def get_or_create do
    case Repo.one(__MODULE__) do
      nil ->
        %__MODULE__{}
        |> changeset(%{})
        |> Repo.insert!()

      config ->
        config
    end
  end
end
