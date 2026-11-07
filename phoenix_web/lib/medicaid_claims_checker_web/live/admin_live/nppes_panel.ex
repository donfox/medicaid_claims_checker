defmodule MedicaidClaimsCheckerWeb.AdminLive.NppesPanel do
  @moduledoc """
  The NPPES Provider Registry panel on the Admin page: refresh status, live
  progress while a refresh runs, and the refresh settings.

  It is not a LiveComponent. `AdminLive` calls `assign_defaults/1` in mount,
  passes NPPES messages to `handle_info/2` and NPPES events to
  `handle_event/3`, and renders `panel/1`. `summary/0` gives the read-only
  status line shown on Claims Intake.
  """
  use MedicaidClaimsCheckerWeb, :html

  alias MedicaidClaimsChecker.Nppes

  @tick_ms 10_000

  @events ~w(nppes_refresh_now nppes_cancel_refresh toggle_nppes_auto_refresh save_nppes_config)

  @doc "The event names this panel handles."
  def events, do: @events

  @doc "True for PubSub and timer messages this panel handles."
  def message?({:nppes_status, _}), do: true
  def message?({:nppes_progress, _}), do: true
  def message?({:nppes_config_updated, _}), do: true
  def message?(:nppes_elapsed_tick), do: true
  def message?(_), do: false

  ## Mount

  @doc "Subscribes (when connected) and sets the panel's assigns."
  def assign_defaults(socket) do
    connected? = Phoenix.LiveView.connected?(socket)
    if connected?, do: Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Nppes.topic())

    status = safe_get_status()

    # If a refresh is already running, pick up its start time and begin ticking.
    {started_at, elapsed_display, timer} =
      if status.refreshing and status[:started_at] do
        started_at = status.started_at
        timer = if connected?, do: Process.send_after(self(), :nppes_elapsed_tick, @tick_ms)
        {started_at, format_elapsed(elapsed_seconds(started_at)), timer}
      else
        {nil, "0s", nil}
      end

    socket
    |> assign(:nppes_config, safe_get_config())
    |> assign(:nppes_refreshing, status.refreshing)
    |> assign(:nppes_provider_count, safe_provider_count())
    |> assign(:nppes_form_error, nil)
    |> assign(:nppes_started_at, started_at)
    |> assign(:nppes_rows_imported, 0)
    |> assign(:nppes_elapsed_display, elapsed_display)
    |> assign(:nppes_elapsed_timer, timer)
  end

  ## Messages

  # A new refresh, or its result, makes any earlier notice (such as a
  # cancel) out of date, so it is cleared. A :cancelled status keeps it.
  def handle_info({:nppes_status, %{status: :running} = payload}, socket) do
    {:noreply,
     socket
     |> Phoenix.LiveView.clear_flash()
     |> start_ticking(Map.get(payload, :started_at, DateTime.utc_now()))
     |> assign(:nppes_config, safe_get_config())}
  end

  def handle_info({:nppes_status, %{status: status}}, socket)
      when status in [:completed, :failed, :cancelled] do
    socket = if status == :cancelled, do: socket, else: Phoenix.LiveView.clear_flash(socket)

    {:noreply,
     socket
     |> stop_ticking()
     |> assign(:nppes_config, safe_get_config())
     |> assign(:nppes_provider_count, safe_provider_count())}
  end

  def handle_info({:nppes_status, _payload}, socket) do
    {:noreply,
     socket
     |> assign(:nppes_config, safe_get_config())
     |> assign(:nppes_refreshing, safe_get_status().refreshing)
     |> assign(:nppes_provider_count, safe_provider_count())}
  end

  def handle_info({:nppes_progress, %{rows_imported: rows}}, socket) do
    {:noreply, assign(socket, :nppes_rows_imported, rows)}
  end

  def handle_info({:nppes_progress, _}, socket), do: {:noreply, socket}

  def handle_info(:nppes_elapsed_tick, %{assigns: %{nppes_refreshing: true}} = socket) do
    timer = Process.send_after(self(), :nppes_elapsed_tick, @tick_ms)

    {:noreply,
     socket
     |> assign(:nppes_elapsed_timer, timer)
     |> assign(
       :nppes_elapsed_display,
       format_elapsed(elapsed_seconds(socket.assigns.nppes_started_at))
     )}
  end

  def handle_info(:nppes_elapsed_tick, socket), do: {:noreply, socket}

  def handle_info({:nppes_config_updated, _config}, socket) do
    {:noreply, assign(socket, :nppes_config, safe_get_config())}
  end

  ## Events

  def handle_event("nppes_refresh_now", _params, socket) do
    Nppes.refresh_now()

    {:noreply,
     socket
     |> Phoenix.LiveView.clear_flash()
     |> start_ticking(DateTime.utc_now() |> DateTime.truncate(:second))}
  end

  def handle_event("nppes_cancel_refresh", _params, socket) do
    Nppes.cancel_refresh()
    message = cancel_message(socket.assigns.nppes_rows_imported)

    {:noreply,
     socket
     |> stop_ticking()
     |> Phoenix.LiveView.put_flash(:info, message)}
  end

  def handle_event("toggle_nppes_auto_refresh", _params, socket) do
    case Nppes.update_refresh_config(%{auto_refresh: !socket.assigns.nppes_config.auto_refresh}) do
      {:ok, updated} ->
        {:noreply, assign(socket, :nppes_config, updated)}

      {:error, _} ->
        {:noreply, assign(socket, :nppes_form_error, "Could not update auto-refresh.")}
    end
  end

  def handle_event("save_nppes_config", %{"nppes" => params}, socket) do
    interval =
      with val when is_binary(val) <- params["interval_seconds"],
           {n, _} <- Integer.parse(val) do
        n
      else
        _ -> nil
      end

    attrs =
      %{interval_seconds: interval, download_url: String.trim(params["download_url"] || "")}
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case Nppes.update_refresh_config(attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:nppes_config, updated)
         |> assign(:nppes_form_error, nil)
         |> Phoenix.LiveView.put_flash(:info, "NPPES settings saved.")}

      {:error, changeset} ->
        message =
          Enum.map_join(changeset.errors, ", ", fn {field, {error, _}} -> "#{field} #{error}" end)

        {:noreply, assign(socket, :nppes_form_error, message)}
    end
  end

  # The import saves rows in batches as it goes, so a cancel during the import
  # leaves the rows already saved with the newer file's details. Nothing is
  # deleted or marked dropped: that happens only after a whole file is read.
  @doc false
  def cancel_message(0), do: "Refresh cancelled. The provider registry is unchanged."

  def cancel_message(rows) do
    "Refresh cancelled after #{format_number(rows)} rows. Those providers keep " <>
      "the newer details; no providers were removed or marked dropped."
  end

  defp start_ticking(socket, started_at) do
    cancel_timer(socket.assigns.nppes_elapsed_timer)

    socket
    |> assign(:nppes_refreshing, true)
    |> assign(:nppes_started_at, started_at)
    |> assign(:nppes_rows_imported, 0)
    |> assign(:nppes_elapsed_display, "0s")
    |> assign(:nppes_elapsed_timer, Process.send_after(self(), :nppes_elapsed_tick, @tick_ms))
  end

  defp stop_ticking(socket) do
    cancel_timer(socket.assigns.nppes_elapsed_timer)

    socket
    |> assign(:nppes_refreshing, false)
    |> assign(:nppes_started_at, nil)
    |> assign(:nppes_rows_imported, 0)
    |> assign(:nppes_elapsed_display, "0s")
    |> assign(:nppes_elapsed_timer, nil)
  end

  ## Read-only summary for Claims Intake

  @doc """
  Status of the registry for display elsewhere:
  `%{state: :refreshing | :completed | :failed | :never, provider_count:, last_refresh_at:}`.
  """
  def summary do
    config = safe_get_config()

    state =
      cond do
        safe_get_status().refreshing -> :refreshing
        config.last_status == "completed" -> :completed
        config.last_status == "failed" -> :failed
        true -> :never
      end

    %{
      state: state,
      provider_count: safe_provider_count(),
      last_refresh_at: config.last_refresh_at
    }
  end

  ## Markup

  attr :nppes_config, :map, required: true
  attr :nppes_refreshing, :boolean, required: true
  attr :nppes_provider_count, :integer, required: true
  attr :nppes_form_error, :string, default: nil
  attr :nppes_rows_imported, :integer, required: true
  attr :nppes_elapsed_display, :string, required: true

  def panel(assigns) do
    ~H"""
    <section id="nppes-panel" class="bg-green-100 border border-green-200 shadow-md rounded-lg">
      <div class="px-4 py-3 border-b border-gray-200">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-lg font-semibold text-gray-900">NPPES Provider Registry</h2>
            <p class="text-xs text-gray-800 mt-1">
              Automated refresh of the National Provider registry used for NPI validation
            </p>
          </div>
          <div :if={!@nppes_refreshing} class="flex items-center gap-3">
            <%= case @nppes_config.last_status do %>
              <% "completed" -> %>
                <span class="px-2 py-1 text-xs bg-green-100 text-green-900 rounded font-medium">
                  Up to date
                </span>
              <% "failed" -> %>
                <span class="px-2 py-1 text-xs bg-red-100 text-red-800 rounded font-medium">
                  Failed
                </span>
              <% _ -> %>
                <span class="px-2 py-1 text-xs bg-gray-200 text-gray-800 rounded font-medium">
                  Never refreshed
                </span>
            <% end %>
            <span class="text-xs text-gray-800">
              {time_ago(@nppes_config.last_refresh_at)} &middot; {format_number(@nppes_provider_count)} providers
            </span>
            <button
              type="button"
              id="nppes-refresh-now"
              phx-click="nppes_refresh_now"
              class="px-3 py-1.5 text-xs font-medium rounded bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
            >
              Refresh Now
            </button>
          </div>
        </div>
      </div>

      <div
        :if={@nppes_refreshing}
        id="nppes-progress"
        class="px-4 py-3 bg-yellow-50 border-t border-b border-yellow-200"
      >
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <span class="relative flex h-3 w-3">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-yellow-400 opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-yellow-500"></span>
            </span>
            <span class="text-sm font-semibold text-yellow-900">Loading NPPES data...</span>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-sm font-medium text-yellow-800">{@nppes_elapsed_display} elapsed</span>
            <span :if={@nppes_rows_imported > 0} class="text-sm text-yellow-700">
              &middot; {format_number(@nppes_rows_imported)} rows imported
            </span>
            <button
              type="button"
              id="nppes-cancel-refresh"
              phx-click="nppes_cancel_refresh"
              class="px-3 py-1.5 text-xs font-medium rounded bg-red-600 hover:bg-red-700 text-white cursor-pointer"
            >
              Cancel
            </button>
          </div>
        </div>
        <div class="w-full bg-yellow-200 rounded-full h-1.5">
          <div class="bg-yellow-500 h-1.5 rounded-full animate-pulse" style="width: 100%"></div>
        </div>
      </div>

      <div
        :if={
          !@nppes_refreshing and @nppes_config.last_status == "failed" and @nppes_config.last_error
        }
        class="px-4 py-3 bg-red-50 border-t border-b border-red-300"
      >
        <div class="flex items-start gap-2">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-600 mt-0.5 shrink-0" />
          <div>
            <p class="text-sm font-semibold text-red-900">NPPES refresh failed</p>
            <p class="text-sm text-red-800 mt-1">{@nppes_config.last_error}</p>
          </div>
        </div>
      </div>

      <div class="p-4">
        <.form for={%{}} phx-submit="save_nppes_config" id="nppes-config-form" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-[auto_1fr_2fr] gap-4 items-start">
            <div>
              <label class="block text-sm font-medium text-gray-900 mb-2">Auto-refresh</label>
              <div class="flex items-center h-[38px]">
                <button
                  type="button"
                  id="nppes-auto-refresh-toggle"
                  phx-click="toggle_nppes_auto_refresh"
                  aria-pressed={to_string(@nppes_config.auto_refresh)}
                  aria-label="Auto-refresh NPPES"
                  class={[
                    "relative inline-flex h-6 w-11 items-center rounded-full transition-colors cursor-pointer",
                    if(@nppes_config.auto_refresh, do: "bg-blue-600", else: "bg-gray-300")
                  ]}
                >
                  <span class={[
                    "inline-block h-4 w-4 transform rounded-full bg-white transition-transform",
                    if(@nppes_config.auto_refresh, do: "translate-x-6", else: "translate-x-1")
                  ]} />
                </button>
                <span class="ml-2 text-xs text-gray-800">
                  {if @nppes_config.auto_refresh, do: "Enabled", else: "Disabled"}
                </span>
              </div>
            </div>

            <div>
              <label for="nppes-interval" class="block text-sm font-medium text-gray-900 mb-2">
                Refresh Interval
              </label>
              <select
                id="nppes-interval"
                name="nppes[interval_seconds]"
                class="w-full px-3 py-2 border border-gray-400 rounded-md text-sm text-gray-900 bg-white"
              >
                <option value="86400" selected={@nppes_config.interval_seconds == 86_400}>
                  Daily
                </option>
                <option value="604800" selected={@nppes_config.interval_seconds == 604_800}>
                  Weekly
                </option>
                <option value="1209600" selected={@nppes_config.interval_seconds == 1_209_600}>
                  Bi-weekly
                </option>
                <option value="2592000" selected={@nppes_config.interval_seconds == 2_592_000}>
                  Monthly
                </option>
              </select>
              <p class="text-[10px] text-gray-800 mt-1">
                Currently: {interval_label(@nppes_config.interval_seconds)}
              </p>
            </div>

            <div>
              <label for="nppes-url" class="block text-sm font-medium text-gray-900 mb-2">
                Download URL
              </label>
              <input
                id="nppes-url"
                name="nppes[download_url]"
                value={@nppes_config.download_url}
                class="w-full px-3 py-2 border border-gray-400 rounded-md text-sm text-gray-900 bg-white"
                placeholder="https://download.cms.gov/nppes/..."
              />
              <p id="nppes-url-help" class="text-[10px] text-gray-800 mt-1">
                A CMS monthly file is switched to the newest month before each refresh.
                Any other URL is used as entered.
              </p>
            </div>
          </div>

          <div :if={@nppes_form_error} class="p-2 bg-red-100 border border-red-300 rounded">
            <p class="text-xs text-red-900">{@nppes_form_error}</p>
          </div>

          <button
            type="submit"
            class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium cursor-pointer"
          >
            Save Settings
          </button>
        </.form>
      </div>
    </section>
    """
  end

  ## Helpers

  defp safe_get_config do
    Nppes.get_refresh_config()
  rescue
    _ -> config_fallback()
  catch
    :exit, _ -> config_fallback()
  end

  defp config_fallback do
    %{
      last_status: "never",
      last_refresh_at: nil,
      last_row_count: 0,
      last_error: nil,
      auto_refresh: true,
      interval_seconds: 604_800,
      download_url: ""
    }
  end

  defp safe_get_status do
    Nppes.get_status()
  catch
    :exit, _ -> %{refreshing: false}
  end

  defp safe_provider_count do
    Nppes.provider_count()
  rescue
    _ -> 0
  end

  @doc "\"19 days ago\" style text for a timestamp; \"Never\" for nil."
  def time_ago(nil), do: "Never"

  def time_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> plural(div(diff, 3600), "hour") <> " ago"
      true -> plural(div(diff, 86_400), "day") <> " ago"
    end
  end

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"

  @doc "Formats an integer with thousands separators: 9852182 -> \"9,852,182\"."
  def format_number(n) when n < 1_000, do: Integer.to_string(n)

  def format_number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp interval_label(86_400), do: "Daily"
  defp interval_label(604_800), do: "Weekly"
  defp interval_label(1_209_600), do: "Bi-weekly"
  defp interval_label(2_592_000), do: "Monthly"
  defp interval_label(_), do: "Custom"

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp elapsed_seconds(nil), do: 0
  defp elapsed_seconds(started_at), do: DateTime.diff(DateTime.utc_now(), started_at, :second)

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_elapsed(seconds), do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
end
