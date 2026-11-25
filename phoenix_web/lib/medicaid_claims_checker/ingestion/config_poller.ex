defmodule MedicaidClaimsChecker.Ingestion.ConfigPoller do
  @moduledoc """
  Polls fetch-source configuration from the local database and dynamically
  updates Quantum fetch jobs.
  """

  use GenServer
  require Logger

  alias MedicaidClaimsChecker.Ingestion
  alias MedicaidClaimsChecker.Ingestion.{FetchRunner, FetchSchedule}
  alias MedicaidClaimsChecker.Scheduler

  @default_poll_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{last_config: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_next_poll()

    case load_config() do
      {:ok, sources} ->
        comparable = config_fingerprint(sources)

        if comparable != state.last_config do
          Logger.info("Ingestion config changed - updating scheduler jobs")
          update_schedules(sources)
          {:noreply, %{state | last_config: comparable}}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # A failed read (database down or restarting) keeps the current jobs and
  # waits for the next poll. Crashing instead would restart the poller, which
  # polls at once and crashes again; three crashes in five seconds make the
  # application supervisor shut down everything, the Repo included.
  defp load_config do
    {:ok, Ingestion.list_enabled_config()}
  rescue
    e ->
      Logger.warning(
        "Ingestion config poll failed, keeping current jobs: #{Exception.message(e)}"
      )

      :error
  end

  defp schedule_next_poll do
    interval =
      Application.get_env(:medicaid_claims_checker, :config_poller, [])
      |> Keyword.get(:poll_interval_ms, @default_poll_interval_ms)

    Process.send_after(self(), :poll, interval)
  end

  defp update_schedules(sources) do
    # Remove all dynamically created fetch jobs.
    Scheduler.jobs()
    |> Enum.filter(fn {name, _job} -> String.starts_with?(to_string(name), "fetch_") end)
    |> Enum.each(fn {name, _job} -> Scheduler.delete_job(name) end)

    Enum.each(sources, fn source ->
      Enum.each(source.fetch_schedules, &add_job(source, &1))
    end)
  end

  # A schedule the scheduler can't run (saved before schedules were checked,
  # or edited in the database) is skipped and logged. Raising here would
  # crash the poller, which restarts and polls at once; three crashes in
  # five seconds stop the whole application.
  defp add_job(source, schedule) do
    job_name = String.to_atom("fetch_#{source.id}_#{schedule.id}")

    case quantum_schedule(schedule) do
      {:ok, quantum_schedule} ->
        timezone =
          Application.get_env(:medicaid_claims_checker, MedicaidClaimsChecker.Scheduler, [])
          |> Keyword.get(:timezone, "Etc/UTC")

        source_map = %{
          id: source.id,
          name: source.name,
          uri: source.uri,
          source_type: source.source_type
        }

        # overlap: false — a slow fetch is not started again while running.
        Scheduler.new_job()
        |> Quantum.Job.set_name(job_name)
        |> Quantum.Job.set_schedule(quantum_schedule)
        |> Quantum.Job.set_timezone(timezone)
        |> Quantum.Job.set_overlap(false)
        |> Quantum.Job.set_task({FetchRunner, :run, [source_map]})
        |> Scheduler.add_job()

        Logger.info(
          "Added scheduler job #{job_name} for #{source.name} (#{schedule.cron_expression || "interval #{schedule.interval_seconds}s"})"
        )

      {:error, reason} ->
        Logger.error("Skipped schedule #{schedule.id} for #{source.name}: #{reason}")
    end
  end

  defp quantum_schedule(%{cron_expression: cron}) when is_binary(cron) do
    Crontab.CronExpression.Parser.parse(cron)
  end

  defp quantum_schedule(%{interval_seconds: seconds}) do
    case FetchSchedule.interval_cron(seconds) do
      {:ok, cron} -> Crontab.CronExpression.Parser.parse(cron)
      :error -> {:error, "interval of #{inspect(seconds)} seconds can't be run exactly"}
    end
  end

  # What the jobs are built from: a change here rebuilds them. Credentials are
  # left out on purpose. Jobs do not carry them (FetchRunner decrypts them when
  # a job runs), so a changed password needs no rebuild, and keeping them here
  # would hold every decrypted password in this process's state, which a crash
  # report prints in full.
  defp config_fingerprint(sources) when is_list(sources) do
    sources
    |> Enum.map(fn source ->
      schedules =
        source.fetch_schedules
        |> Enum.map(fn s ->
          %{id: s.id, cron_expression: s.cron_expression, interval_seconds: s.interval_seconds}
        end)
        |> Enum.sort_by(& &1.id)

      %{
        id: source.id,
        name: source.name,
        uri: source.uri,
        source_type: source.source_type,
        schedules: schedules
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
