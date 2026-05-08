defmodule MedicaidClaimsChecker.Ingestion do
  @moduledoc """
  Context for managing fetch sources and schedules.
  Local scheduler jobs read this config to know what to fetch and when.
  """
  import Ecto.Query
  alias MedicaidClaimsChecker.Repo
  alias MedicaidClaimsChecker.Ingestion.{FetchSource, FetchSchedule}

  # --- FetchSource operations ---

  def list_fetch_sources do
    FetchSource
    |> order_by(asc: :name)
    |> preload(:fetch_schedules)
    |> Repo.all()
  end

  def get_fetch_source!(id) do
    FetchSource
    |> preload(:fetch_schedules)
    |> Repo.get!(id)
  end

  def create_fetch_source(attrs) do
    %FetchSource{}
    |> FetchSource.changeset(attrs)
    |> Repo.insert()
  end

  def update_fetch_source(%FetchSource{} = source, attrs) do
    source
    |> FetchSource.changeset(attrs)
    |> Repo.update()
  end

  def delete_fetch_source(%FetchSource{} = source) do
    Repo.delete(source)
  end

  def toggle_fetch_source_enabled(%FetchSource{} = source) do
    update_fetch_source(source, %{enabled: !source.enabled})
  end

  # --- FetchSchedule operations ---

  def get_fetch_schedule!(id), do: Repo.get!(FetchSchedule, id)

  def create_fetch_schedule(attrs) do
    %FetchSchedule{}
    |> FetchSchedule.changeset(attrs)
    |> Repo.insert()
  end

  def update_fetch_schedule(%FetchSchedule{} = schedule, attrs) do
    schedule
    |> FetchSchedule.changeset(attrs)
    |> Repo.update()
  end

  def delete_fetch_schedule(%FetchSchedule{} = schedule) do
    Repo.delete(schedule)
  end

  def toggle_fetch_schedule_enabled(%FetchSchedule{} = schedule) do
    update_fetch_schedule(schedule, %{enabled: !schedule.enabled})
  end

  # --- Config endpoint query ---

  def list_enabled_config do
    enabled_schedules_query = from(s in FetchSchedule, where: s.enabled == true)

    FetchSource
    |> where([s], s.enabled == true)
    |> preload(fetch_schedules: ^enabled_schedules_query)
    |> Repo.all()
  end
end
