defmodule MedicaidClaimsChecker.Ingestion do
  @moduledoc """
  Context for managing fetch sources and schedules.
  Local scheduler jobs read this config to know what to fetch and when.
  """
  import Ecto.Query
  alias MedicaidClaimsChecker.Repo
  alias MedicaidClaimsChecker.Ingestion.{FetchedFile, FetchSource, FetchSchedule}

  # --- FetchSource operations ---

  def list_fetch_sources do
    FetchSource
    |> order_by(asc: :name)
    |> preload(:fetch_schedules)
    |> Repo.all()
  end

  def get_fetch_source(id), do: Repo.get(FetchSource, id)

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

  @doc "Returns enabled fetch sources with their enabled schedules preloaded. Used by the config polling endpoint."
  def list_enabled_config do
    enabled_schedules_query = from(s in FetchSchedule, where: s.enabled == true)

    FetchSource
    |> where([s], s.enabled == true)
    |> preload(fetch_schedules: ^enabled_schedules_query)
    |> Repo.all()
  end

  # --- Files a source has already fetched ---

  @doc "The `{filename, sha256}` pairs among `files` that `source_id` has fetched before."
  def already_fetched(source_id, files) do
    shas = files |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    FetchedFile
    |> where([f], f.fetch_source_id == ^source_id and f.sha256 in ^shas)
    |> select([f], {f.filename, f.sha256})
    |> Repo.all()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(files))
  end

  @doc "Records `{filename, sha256}` pairs as fetched by `source_id`."
  def record_fetched(source_id, files) do
    now = DateTime.utc_now(:second)

    rows =
      files
      |> Enum.uniq()
      |> Enum.map(fn {name, sha} ->
        %{fetch_source_id: source_id, filename: name, sha256: sha, inserted_at: now}
      end)

    Repo.insert_all(FetchedFile, rows, on_conflict: :nothing)
    :ok
  end
end
