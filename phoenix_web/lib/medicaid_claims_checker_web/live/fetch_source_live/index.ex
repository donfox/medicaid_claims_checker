defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.Index do
  use MedicaidClaimsCheckerWeb, :live_view

  alias MedicaidClaimsChecker.Ingestion
  alias MedicaidClaimsChecker.Nppes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Nppes.topic())
    end

    nppes_config = safe_get_nppes_config()
    nppes_status = safe_get_nppes_status()

    # If a refresh is already running, pick up its start time and begin ticking
    {started_at, elapsed_display, timer} =
      if nppes_status.refreshing and nppes_status.started_at do
        sa = nppes_status.started_at
        el = format_elapsed(elapsed_seconds(sa))
        t = if connected?(socket), do: Process.send_after(self(), :nppes_elapsed_tick, 10_000), else: nil
        {sa, el, t}
      else
        {nil, "0s", nil}
      end

    {:ok,
     socket
     |> assign(:sources, Ingestion.list_fetch_sources())
     |> assign(:show_source_form, false)
     |> assign(:editing_source, nil)
     |> assign(:form_error, nil)
     |> assign(:source_name, "")
     |> assign(:source_uri, "")
     |> assign(:source_type, "sftp")
     |> assign(:expanded_source_ids, MapSet.new())
     |> assign(:adding_schedule_for, nil)
     |> assign(:schedule_cron, "")
     |> assign(:schedule_interval, "")
     |> assign(:source_password, "")
     |> assign(:source_username, "")
     |> assign(:nppes_config, nppes_config)
     |> assign(:nppes_refreshing, nppes_status.refreshing)
     |> assign(:nppes_provider_count, safe_provider_count())
     |> assign(:nppes_form_error, nil)
     |> assign(:nppes_started_at, started_at)
     |> assign(:nppes_rows_imported, 0)
     |> assign(:nppes_elapsed_display, elapsed_display)
     |> assign(:nppes_elapsed_timer, timer)}
  end

  # --- NPPES PubSub handlers ---

  @impl true
  def handle_info({:nppes_status, %{status: :running} = payload}, socket) do
    cancel_elapsed_timer(socket.assigns.nppes_elapsed_timer)
    timer = Process.send_after(self(), :nppes_elapsed_tick, 10_000)

    {:noreply,
     socket
     |> assign(:nppes_config, safe_get_nppes_config())
     |> assign(:nppes_refreshing, true)
     |> assign(:nppes_started_at, Map.get(payload, :started_at, DateTime.utc_now()))
     |> assign(:nppes_rows_imported, 0)
     |> assign(:nppes_elapsed_display, "0s")
     |> assign(:nppes_elapsed_timer, timer)}
  end

  def handle_info({:nppes_status, %{status: status}}, socket) when status in [:completed, :failed, :cancelled] do
    cancel_elapsed_timer(socket.assigns.nppes_elapsed_timer)

    {:noreply,
     socket
     |> assign(:nppes_config, safe_get_nppes_config())
     |> assign(:nppes_refreshing, false)
     |> assign(:nppes_provider_count, safe_provider_count())
     |> assign(:nppes_started_at, nil)
     |> assign(:nppes_rows_imported, 0)
     |> assign(:nppes_elapsed_display, "0s")
     |> assign(:nppes_elapsed_timer, nil)}
  end

  def handle_info({:nppes_status, _payload}, socket) do
    {:noreply,
     socket
     |> assign(:nppes_config, safe_get_nppes_config())
     |> assign(:nppes_refreshing, safe_get_nppes_status().refreshing)
     |> assign(:nppes_provider_count, safe_provider_count())}
  end

  def handle_info({:nppes_progress, %{rows_imported: rows}}, socket) do
    {:noreply, assign(socket, :nppes_rows_imported, rows)}
  end

  def handle_info(:nppes_elapsed_tick, %{assigns: %{nppes_refreshing: true}} = socket) do
    timer = Process.send_after(self(), :nppes_elapsed_tick, 10_000)
    elapsed_sec = elapsed_seconds(socket.assigns.nppes_started_at)

    {:noreply,
     socket
     |> assign(:nppes_elapsed_timer, timer)
     |> assign(:nppes_elapsed_display, format_elapsed(elapsed_sec))}
  end

  def handle_info(:nppes_elapsed_tick, socket) do
    {:noreply, socket}
  end

  def handle_info({:nppes_config_updated, _config}, socket) do
    {:noreply, assign(socket, :nppes_config, safe_get_nppes_config())}
  end

  # --- NPPES event handlers ---

  @impl true
  def handle_event("nppes_refresh_now", _params, socket) do
    cancel_elapsed_timer(socket.assigns.nppes_elapsed_timer)
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)
    timer = Process.send_after(self(), :nppes_elapsed_tick, 10_000)

    Nppes.refresh_now()

    {:noreply,
     socket
     |> assign(:nppes_refreshing, true)
     |> assign(:nppes_started_at, started_at)
     |> assign(:nppes_rows_imported, 0)
     |> assign(:nppes_elapsed_display, "0s")
     |> assign(:nppes_elapsed_timer, timer)}
  end

  def handle_event("nppes_cancel_refresh", _params, socket) do
    cancel_elapsed_timer(socket.assigns.nppes_elapsed_timer)
    Nppes.cancel_refresh()

    {:noreply,
     socket
     |> assign(:nppes_refreshing, false)
     |> assign(:nppes_started_at, nil)
     |> assign(:nppes_elapsed_display, "0s")
     |> assign(:nppes_elapsed_timer, nil)}
  end

  def handle_event("toggle_nppes_auto_refresh", _params, socket) do
    config = socket.assigns.nppes_config
    new_val = !config.auto_refresh

    case Nppes.update_refresh_config(%{auto_refresh: new_val}) do
      {:ok, updated} ->
        {:noreply, assign(socket, :nppes_config, updated)}

      {:error, _} ->
        {:noreply, assign(socket, :nppes_form_error, "Could not update auto-refresh.")}
    end
  end

  def handle_event("save_nppes_config", %{"nppes" => params}, socket) do
    interval =
      case params["interval_seconds"] do
        val when is_binary(val) ->
          case Integer.parse(val) do
            {n, _} -> n
            :error -> nil
          end

        _ ->
          nil
      end

    attrs = %{
      interval_seconds: interval,
      download_url: String.trim(params["download_url"] || "")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()

    case Nppes.update_refresh_config(attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:nppes_config, updated)
         |> assign(:nppes_form_error, nil)
         |> put_flash(:info, "NPPES settings saved.")}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, :nppes_form_error, message)}
    end
  end

  @impl true
  def handle_event("toggle_add_source_form", _params, socket) do
    showing = !socket.assigns.show_source_form

    {:noreply,
     socket
     |> assign(:show_source_form, showing)
     |> assign(:editing_source, nil)
     |> assign(:form_error, nil)
     |> reset_source_form()}
  end

  def handle_event("edit_source", %{"id" => id}, socket) do
    source = Ingestion.get_fetch_source!(id)

    {:noreply,
     socket
     |> assign(:show_source_form, true)
     |> assign(:editing_source, source)
     |> assign(:source_name, source.name)
     |> assign(:source_uri, source.uri)
     |> assign(:source_type, source.source_type)
     |> assign(:source_password, "")
     |> assign(:source_username, get_in(source.credentials, ["username"]) || "")
     |> assign(:form_error, nil)}
  end

  def handle_event("save_source", %{"source" => params}, socket) do
    password = String.trim(params["password"] || "")
    username = String.trim(params["username"] || "")

    credentials =
      case socket.assigns.editing_source do
        nil -> %{}
        source -> source.credentials || %{}
      end

    credentials =
      credentials
      |> then(fn c -> if password != "", do: Map.put(c, "password", password), else: c end)
      |> then(fn c -> if username != "", do: Map.put(c, "username", username), else: Map.delete(c, "username") end)

    attrs = %{
      name: String.trim(params["name"] || ""),
      uri: String.trim(params["uri"] || ""),
      source_type: params["type"] || "sftp",
      credentials: credentials
    }

    result =
      case socket.assigns.editing_source do
        nil -> Ingestion.create_fetch_source(attrs)
        source -> Ingestion.update_fetch_source(source, attrs)
      end

    case result do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(:sources, Ingestion.list_fetch_sources())
         |> assign(:show_source_form, false)
         |> assign(:editing_source, nil)
         |> assign(:form_error, nil)
         |> reset_source_form()
         |> put_flash(:info, if(socket.assigns.editing_source, do: "Source updated.", else: "Source added."))}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    source = Ingestion.get_fetch_source!(id)

    case Ingestion.delete_fetch_source(source) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:sources, Ingestion.list_fetch_sources())
         |> put_flash(:info, "Source deleted.")}

      {:error, _} ->
        {:noreply, assign(socket, :form_error, "Could not delete source.")}
    end
  end

  def handle_event("toggle_source_enabled", %{"id" => id}, socket) do
    source = Ingestion.get_fetch_source!(id)
    {:ok, _} = Ingestion.toggle_fetch_source_enabled(source)
    {:noreply, assign(socket, :sources, Ingestion.list_fetch_sources())}
  end

  def handle_event("toggle_expand_source", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded_source_ids

    updated =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_source_ids, updated)}
  end

  # --- Schedule events ---

  def handle_event("show_add_schedule", %{"source-id" => source_id}, socket) do
    {:noreply,
     socket
     |> assign(:adding_schedule_for, String.to_integer(source_id))
     |> assign(:schedule_cron, "")
     |> assign(:schedule_interval, "")}
  end

  def handle_event("cancel_add_schedule", _params, socket) do
    {:noreply, assign(socket, :adding_schedule_for, nil)}
  end

  def handle_event("update_schedule_form", %{"schedule" => params}, socket) do
    {:noreply,
     socket
     |> assign(:schedule_cron, params["cron"] || "")
     |> assign(:schedule_interval, params["interval"] || "")}
  end

  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    source_id = socket.assigns.adding_schedule_for

    attrs =
      cond do
        String.trim(params["cron"] || "") != "" ->
          %{fetch_source_id: source_id, cron_expression: String.trim(params["cron"])}

        String.trim(params["interval"] || "") != "" ->
          case Integer.parse(params["interval"]) do
            {seconds, _} -> %{fetch_source_id: source_id, interval_seconds: seconds}
            :error -> %{fetch_source_id: source_id}
          end

        true ->
          %{fetch_source_id: source_id}
      end

    case Ingestion.create_fetch_schedule(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:sources, Ingestion.list_fetch_sources())
         |> assign(:adding_schedule_for, nil)}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    schedule = Ingestion.get_fetch_schedule!(id)
    {:ok, _} = Ingestion.delete_fetch_schedule(schedule)
    {:noreply, assign(socket, :sources, Ingestion.list_fetch_sources())}
  end

  def handle_event("toggle_schedule_enabled", %{"id" => id}, socket) do
    schedule = Ingestion.get_fetch_schedule!(id)
    {:ok, _} = Ingestion.toggle_fetch_schedule_enabled(schedule)
    {:noreply, assign(socket, :sources, Ingestion.list_fetch_sources())}
  end

  defp reset_source_form(socket) do
    socket
    |> assign(:source_name, "")
    |> assign(:source_uri, "")
    |> assign(:source_type, "sftp")
    |> assign(:source_password, "")
    |> assign(:source_username, "")
  end

  defp schedule_description(schedule) do
    cond do
      schedule.cron_expression -> "Cron: #{schedule.cron_expression}"
      schedule.interval_seconds -> "Every #{humanize_interval(schedule.interval_seconds)}"
      true -> "No schedule"
    end
  end

  defp humanize_interval(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  defp humanize_interval(seconds) when seconds < 86400, do: "#{div(seconds, 3600)} hr"
  defp humanize_interval(seconds), do: "#{div(seconds, 86400)} day"

  defp source_type_label("sftp"), do: "SFTP"
  defp source_type_label("local"), do: "Local"
  defp source_type_label("http"), do: "HTTP"
  defp source_type_label("databricks"), do: "Databricks"
  defp source_type_label(other), do: other

  # --- NPPES helpers ---

  defp safe_get_nppes_config do
    Nppes.get_refresh_config()
  rescue
    _ -> nppes_config_fallback()
  catch
    :exit, _ -> nppes_config_fallback()
  end

  defp nppes_config_fallback do
    %{last_status: "never", last_refresh_at: nil, last_row_count: 0, last_error: nil, auto_refresh: true, interval_seconds: 604_800, download_url: ""}
  end

  defp safe_get_nppes_status do
    Nppes.get_status()
  catch
    :exit, _ -> %{refreshing: false}
  end

  defp safe_provider_count do
    Nppes.provider_count()
  rescue
    _ -> 0
  end

  defp format_nppes_time(nil), do: "Never"

  defp format_nppes_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86_400)} days ago"
    end
  end

  defp interval_label(86_400), do: "Daily"
  defp interval_label(604_800), do: "Weekly"
  defp interval_label(1_209_600), do: "Bi-weekly"
  defp interval_label(2_592_000), do: "Monthly"
  defp interval_label(_), do: "Custom"

  defp cancel_elapsed_timer(nil), do: :ok
  defp cancel_elapsed_timer(ref), do: Process.cancel_timer(ref)

  defp elapsed_seconds(nil), do: 0
  defp elapsed_seconds(started_at), do: DateTime.diff(DateTime.utc_now(), started_at, :second)

  defp format_elapsed(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_elapsed(seconds), do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_number(n) when n < 1_000, do: Integer.to_string(n)

  defp format_number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
end
