defmodule MedicaidClaimsChecker.Nppes do
  @moduledoc """
  Context for NPPES provider registry refresh management.
  """

  alias MedicaidClaimsChecker.Repo
  alias MedicaidClaimsChecker.Claims.NppesProvider
  alias MedicaidClaimsChecker.Nppes.{RefreshConfig, RefreshWorker}

  @topic "nppes_refresh"

  def topic, do: @topic

  def get_refresh_config do
    RefreshConfig.get_or_create()
  end

  def update_refresh_config(attrs) do
    config = RefreshConfig.get_or_create()

    case config |> RefreshConfig.changeset(attrs) |> Repo.update() do
      {:ok, updated} = result ->
        RefreshWorker.update_config(attrs)
        broadcast({:nppes_config_updated, updated})
        result

      error ->
        error
    end
  end

  def provider_count do
    Repo.aggregate(NppesProvider, :count)
  end

  def refresh_now do
    RefreshWorker.refresh_now()
  end

  def cancel_refresh do
    RefreshWorker.cancel_refresh()
  end

  def get_status do
    RefreshWorker.get_status()
  end

  def broadcast(message) do
    Phoenix.PubSub.broadcast(MedicaidClaimsChecker.PubSub, @topic, message)
  end
end
