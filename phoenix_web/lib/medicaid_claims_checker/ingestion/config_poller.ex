defmodule MedicaidClaimsChecker.Ingestion.ConfigPoller do
  @moduledoc """
  Polls fetch-source configuration from the local database and dynamically
  updates Quantum fetch jobs.
  """

  use GenServer
  require Logger

  alias MedicaidClaimsChecker.Ingestion
  alias MedicaidClaimsChecker.Ingestion.FetchRunner
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

    sources = Ingestion.list_enabled_config()
    comparable = config_fingerprint(sources)

    if comparable != state.last_config do
      Logger.info("Ingestion config changed - updating scheduler jobs")
      update_schedules(sources)
      {:noreply, %{state | last_config: comparable}}
    else
      {:noreply, state}
    end
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
      Enum.each(source.fetch_schedules, fn schedule ->
        job_name = String.to_atom("fetch_#{source.id}_#{schedule.id}")

        quantum_schedule =
          if schedule.cron_expression do
            Crontab.CronExpression.Parser.parse!(schedule.cron_expression)
          else
            build_interval_schedule(schedule.interval_seconds)
          end

        timezone =
          Application.get_env(:medicaid_claims_checker, MedicaidClaimsChecker.Scheduler, [])
          |> Keyword.get(:timezone, "Etc/UTC")

        source_map = %{
          id: source.id,
          name: source.name,
          uri: source.uri,
          source_type: source.source_type
        }

        job =
          Scheduler.new_job()
          |> Quantum.Job.set_name(job_name)
          |> Quantum.Job.set_schedule(quantum_schedule)
          |> Quantum.Job.set_timezone(timezone)
          |> Quantum.Job.set_task({FetchRunner, :run, [source_map]})

        Scheduler.add_job(job)

        Logger.info(
          "Added scheduler job #{job_name} for #{source.name} (#{schedule.cron_expression || "interval #{schedule.interval_seconds}s"})"
        )
      end)
    end)
  end

  defp build_interval_schedule(seconds) when is_integer(seconds) and seconds <= 60 do
    Crontab.CronExpression.Parser.parse!("* * * * *")
  end

  defp build_interval_schedule(seconds) when is_integer(seconds) and seconds <= 3600 do
    minutes = div(seconds, 60)
    Crontab.CronExpression.Parser.parse!("*/#{minutes} * * * *")
  end

  defp build_interval_schedule(seconds) when is_integer(seconds) do
    hours = max(div(seconds, 3600), 1)
    Crontab.CronExpression.Parser.parse!("0 */#{hours} * * *")
  end

  defp build_interval_schedule(_), do: Crontab.CronExpression.Parser.parse!("0 * * * *")

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
        uri: source.uri,
        source_type: source.source_type,
        credentials: source.credentials,
        schedules: schedules
      }
    end)
    |> Enum.sort_by(& &1.id)
  end
end
