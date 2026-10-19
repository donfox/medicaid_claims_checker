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
    field(:entity_type, :integer)
    field(:provider_name, :string)
    field(:credential, :string)
    # Keep taxonomy optional for compatibility with databases that predate
    # the taxonomy migration. It can still be explicitly selected when needed.
    field(:taxonomy, :string, load_in_query: false)
    field(:state, :string)
    field(:enumeration_date, :date)
    field(:deactivation_date, :date)
    field(:reactivation_date, :date)
    field(:last_update_date, :date)
    # Date of the first full NPPES import this NPI was missing from; nil
    # while CMS still lists it. Dropped NPIs are kept for late claims.
    field(:dropped_on, :date)

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :npi,
      :entity_type,
      :provider_name,
      :credential,
      :taxonomy,
      :state,
      :enumeration_date,
      :deactivation_date,
      :reactivation_date,
      :last_update_date,
      :dropped_on
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
  - Reactivated after the deactivation, and service on or after the
    reactivation → active (provider was reinstated)
  - Otherwise → deactivated at time of service, including a service date
    between deactivation and reactivation
  """
  def active_on_date?(%__MODULE__{deactivation_date: nil}, _service_date), do: true

  def active_on_date?(
        %__MODULE__{deactivation_date: deact, reactivation_date: react},
        service_date
      ) do
    cond do
      Date.compare(service_date, deact) in [:lt, :eq] ->
        true

      react != nil and Date.compare(react, deact) == :gt and
          Date.compare(service_date, react) != :lt ->
        true

      true ->
        false
    end
  end

  @doc "True unless the service date is before the NPI was issued (enumerated)."
  def issued_by?(%__MODULE__{enumeration_date: nil}, _service_date), do: true

  def issued_by?(%__MODULE__{enumeration_date: enumerated}, service_date),
    do: Date.compare(service_date, enumerated) != :lt

  @doc """
  True unless the service date is on or after the NPI was dropped from the
  NPPES file. Services before the drop are judged on the last known record.
  """
  def listed_on?(%__MODULE__{dropped_on: nil}, _service_date), do: true

  def listed_on?(%__MODULE__{dropped_on: dropped}, service_date),
    do: Date.compare(service_date, dropped) == :lt
end
