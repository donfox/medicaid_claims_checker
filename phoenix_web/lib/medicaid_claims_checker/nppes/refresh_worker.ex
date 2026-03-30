defmodule MedicaidClaimsChecker.Nppes.RefreshWorker do
  @moduledoc """
  GenServer that periodically downloads and imports NPPES provider data.

  Reads configuration from the `nppes_refresh_config` table and schedules
  imports based on the configured interval. Import work runs in a supervised
  task so this process stays responsive to status queries and config updates.
  """

  use GenServer

  alias MedicaidClaimsChecker.Repo
  alias MedicaidClaimsChecker.Nppes
  alias MedicaidClaimsChecker.Nppes.{RefreshConfig, Importer}

  require Logger

  # Give the app 10 seconds to fully start before first check
  @initial_delay_ms 10_000

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def refresh_now do
    GenServer.cast(__MODULE__, :refresh_now)
  end

  def update_config(changes) do
    GenServer.cast(__MODULE__, {:update_config, changes})
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  def cancel_refresh do
    GenServer.cast(__MODULE__, :cancel_refresh)
  end

  # --- Callbacks ---

  @impl true
  def init(_) do
    timer_ref = Process.send_after(self(), :tick, @initial_delay_ms)
    {:ok, %{timer_ref: timer_ref, refreshing: false, task_ref: nil, task_pid: nil, started_at: nil}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, %{refreshing: state.refreshing, started_at: state.started_at}, state}
  end

  @impl true
  def handle_cast(:refresh_now, %{refreshing: true} = state) do
    Nppes.broadcast({:nppes_status, %{status: :already_running}})
    {:noreply, state}
  end

  def handle_cast(:refresh_now, state) do
    cancel_timer(state.timer_ref)
    new_state = start_import(state)
    {:noreply, new_state}
  end

  def handle_cast(:cancel_refresh, %{refreshing: false} = state) do
    {:noreply, state}
  end

  def handle_cast(:cancel_refresh, %{task_pid: pid, task_ref: ref} = state) do
    if pid, do: Process.exit(pid, :kill)
    if ref, do: Process.demonitor(ref, [:flush])

    config = RefreshConfig.get_or_create()

    config
    |> RefreshConfig.changeset(%{last_status: "failed", last_error: "Cancelled by user"})
    |> Repo.update!()

    Logger.info("NPPES refresh cancelled by user")
    Nppes.broadcast({:nppes_status, %{status: :cancelled}})

    timer_ref = schedule_tick(config.interval_seconds)
    {:noreply, %{state | refreshing: false, task_ref: nil, task_pid: nil, timer_ref: timer_ref, started_at: nil}}
  end

  def handle_cast({:update_config, _changes}, state) do
    cancel_timer(state.timer_ref)

    config = RefreshConfig.get_or_create()

    timer_ref =
      if config.auto_refresh do
        schedule_tick(config.interval_seconds)
      else
        nil
      end

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:tick, %{refreshing: true} = state) do
    # Already running — reschedule and skip
    config = RefreshConfig.get_or_create()
    timer_ref = schedule_tick(config.interval_seconds)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:tick, state) do
    config = RefreshConfig.get_or_create()

    if config.auto_refresh and should_refresh?(config) do
      new_state = start_import(state)
      {:noreply, new_state}
    else
      timer_ref = schedule_tick(config.interval_seconds)
      {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  # Task completed successfully
  def handle_info({ref, {:ok, count}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    config = RefreshConfig.get_or_create()

    config
    |> RefreshConfig.changeset(%{
      last_status: "completed",
      last_refresh_at: now,
      last_row_count: count,
      last_error: nil
    })
    |> Repo.update!()

    Logger.info("NPPES refresh completed: #{count} providers")
    Nppes.broadcast({:nppes_status, %{status: :completed, row_count: count, refreshed_at: now}})

    timer_ref = schedule_tick(config.interval_seconds)
    {:noreply, %{state | refreshing: false, task_ref: nil, task_pid: nil, timer_ref: timer_ref, started_at: nil}}
  end

  # Task returned an error
  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    handle_failure(state, reason)
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    handle_failure(state, inspect(reason))
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp start_import(state) do
    config = RefreshConfig.get_or_create()

    config
    |> RefreshConfig.changeset(%{last_status: "running", last_error: nil})
    |> Repo.update!()

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Logger.info("NPPES refresh starting (download from #{config.download_url})")
    Nppes.broadcast({:nppes_status, %{status: :running, started_at: started_at}})

    progress_callback = fn rows ->
      Nppes.broadcast({:nppes_progress, %{rows_imported: rows}})
    end

    %Task{ref: ref, pid: pid} =
      Task.Supervisor.async_nolink(MedicaidClaimsChecker.TaskSupervisor, fn ->
        Importer.download_and_import(config.download_url, on_progress: progress_callback)
      end)

    %{state | refreshing: true, task_ref: ref, task_pid: pid, timer_ref: nil, started_at: started_at}
  end

  defp handle_failure(state, reason) do
    config = RefreshConfig.get_or_create()
    error_msg = if is_binary(reason), do: reason, else: inspect(reason)

    config
    |> RefreshConfig.changeset(%{last_status: "failed", last_error: error_msg})
    |> Repo.update!()

    Logger.error("NPPES refresh failed: #{error_msg}")
    Nppes.broadcast({:nppes_status, %{status: :failed, error: error_msg}})

    timer_ref = schedule_tick(config.interval_seconds)
    {:noreply, %{state | refreshing: false, task_ref: nil, task_pid: nil, timer_ref: timer_ref, started_at: nil}}
  end

  defp should_refresh?(config) do
    case config.last_refresh_at do
      nil -> true
      last -> DateTime.diff(DateTime.utc_now(), last, :second) >= config.interval_seconds
    end
  end

  defp schedule_tick(interval_seconds) do
    Process.send_after(self(), :tick, interval_seconds * 1_000)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
