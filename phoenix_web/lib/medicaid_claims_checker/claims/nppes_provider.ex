defmodule MedicaidClaimsChecker.Claims.NppesProvider do
  @moduledoc """
  Ecto schema for the `nppes_providers` table.

  Stores a subset of the NPPES (National Plan and Provider Enumeration System)
  bulk download — just enough to answer "was this NPI active on a given date?"
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:npi, :string, autogenerate: false}

  schema "nppes_providers" do
    field :entity_type, :integer
    field :provider_name, :string
    field :credential, :string
    field :state, :string
    field :enumeration_date, :date
    field :deactivation_date, :date
    field :reactivation_date, :date
    field :last_update_date, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :npi,
      :entity_type,
      :provider_name,
      :credential,
      :state,
      :enumeration_date,
      :deactivation_date,
      :reactivation_date,
      :last_update_date
    ])
    |> validate_required([:npi, :entity_type, :provider_name])
    |> validate_length(:npi, is: 10)
    |> validate_inclusion(:entity_type, [1, 2])
  end

  @doc """
  Returns true if the provider was active on the given `service_date`.

  Logic:
  - No deactivation date → active (provider never deactivated)
  - Service date on or before deactivation → active (treatment before deactivation)
  - Reactivation date after deactivation → active (provider was reinstated)
  - Otherwise → deactivated at time of service
  """
  def active_on_date?(%__MODULE__{deactivation_date: nil}, _service_date), do: true

  def active_on_date?(%__MODULE__{deactivation_date: deact, reactivation_date: react}, service_date) do
    cond do
      Date.compare(service_date, deact) in [:lt, :eq] -> true
      react != nil and Date.compare(react, deact) == :gt -> true
      true -> false
    end
  end
end
