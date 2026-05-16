defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.Index do
  use MedicaidClaimsCheckerWeb, :live_view

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Evaluator
  alias MedicaidClaimsChecker.Ingestion
  alias MedicaidClaimsChecker.Nppes
  alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Nppes.topic())
      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Evaluator.topic())
    end

    nppes_config = safe_get_nppes_config()
    nppes_status = safe_get_nppes_status()

    # If a refresh is already running, pick up its start time and begin ticking
    {started_at, elapsed_display, timer} =
      if nppes_status.refreshing and nppes_status.started_at do
        sa = nppes_status.started_at
        el = format_elapsed(elapsed_seconds(sa))

        t =
          if connected?(socket),
            do: Process.send_after(self(), :nppes_elapsed_tick, 10_000),
            else: nil

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
     |> assign(:editing_schedule, nil)
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
     |> assign(:nppes_elapsed_timer, timer)
     |> assign(:batch_history, load_batch_history())
     |> assign(:show_batch_history, false)
     |> assign(:expanded_batch_ids, MapSet.new())
     |> assign(:expanded_batch_file_ids, MapSet.new())
     |> assign(:batch_risk_filter, nil)
     |> assign(:upload_status, :idle)
     |> assign(:upload_message, nil)
     |> allow_upload(:manual_files,
       accept: ~w(.json .x12 .edi .zip),
       max_entries: 100,
       max_file_size: 10_000_000,
       auto_upload: true
     )}
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

  def handle_info({:nppes_status, %{status: status}}, socket)
      when status in [:completed, :failed, :cancelled] do
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

  # --- Batch completion handlers ---

  def handle_info({:batch_completed, %{batch_id: batch_id}}, socket) do
    {:noreply, merge_batch_update(socket, batch_id)}
  end

  def handle_info({:batch_completed, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:batch_failed, %{batch_id: batch_id}}, socket) do
    {:noreply, merge_batch_update(socket, batch_id)}
  end

  def handle_info({:batch_failed, _payload}, socket) do
    {:noreply, socket}
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

    attrs =
      %{
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
      |> then(fn c ->
        if username != "", do: Map.put(c, "username", username), else: Map.delete(c, "username")
      end)

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
         |> put_flash(
           :info,
           if(socket.assigns.editing_source, do: "Source updated.", else: "Source added.")
         )}

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
     |> assign(:editing_schedule, nil)
     |> assign(:schedule_cron, "")
     |> assign(:schedule_interval, "")}
  end

  def handle_event("edit_schedule", %{"id" => id, "source-id" => source_id}, socket) do
    schedule = Ingestion.get_fetch_schedule!(id)

    {:noreply,
     socket
     |> assign(:adding_schedule_for, String.to_integer(source_id))
     |> assign(:editing_schedule, schedule)
     |> assign(:schedule_cron, schedule.cron_expression || "")
     |> assign(
       :schedule_interval,
       if(schedule.interval_seconds, do: to_string(schedule.interval_seconds), else: "")
     )}
  end

  def handle_event("cancel_add_schedule", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_schedule_for, nil)
     |> assign(:editing_schedule, nil)}
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
          %{
            fetch_source_id: source_id,
            cron_expression: String.trim(params["cron"]),
            interval_seconds: nil
          }

        String.trim(params["interval"] || "") != "" ->
          case Integer.parse(params["interval"]) do
            {seconds, _} ->
              %{fetch_source_id: source_id, interval_seconds: seconds, cron_expression: nil}

            :error ->
              %{fetch_source_id: source_id}
          end

        true ->
          %{fetch_source_id: source_id}
      end

    result =
      case socket.assigns.editing_schedule do
        nil -> Ingestion.create_fetch_schedule(attrs)
        schedule -> Ingestion.update_fetch_schedule(schedule, attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:sources, Ingestion.list_fetch_sources())
         |> assign(:adding_schedule_for, nil)
         |> assign(:editing_schedule, nil)}

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

  # --- Manual Upload event handlers ---

  def handle_event("validate_manual_uploads", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("clear_manual_uploads", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.manual_files.entries, socket, fn entry, acc_socket ->
        cancel_upload(acc_socket, :manual_files, entry.ref)
      end)

    {:noreply,
     socket
     |> assign(:upload_status, :idle)
     |> assign(:upload_message, nil)}
  end

  def handle_event("process_manual_upload", _params, socket) do
    socket = assign(socket, :upload_message, nil)

    files =
      consume_uploaded_entries(socket, :manual_files, fn %{path: path}, entry ->
        content = File.read!(path)
        {:ok, {entry.client_name, content}}
      end)

    if files == [] do
      {:noreply,
       socket
       |> assign(:upload_status, :error)
       |> assign(:upload_message, "No valid files to process.")}
    else
      # Split files by extension
      {json_files, x12_files, zip_files} = classify_files(files)

      # Extract zip files and classify their contents
      {zip_json, zip_x12} = extract_and_classify_zips(zip_files)
      json_files = json_files ++ zip_json
      x12_files = x12_files ++ zip_x12

      if json_files == [] and x12_files == [] do
        {:noreply,
         socket
         |> assign(:upload_status, :error)
         |> assign(
           :upload_message,
           "No processable claims found. Supported file types: .json, .x12, .edi, .zip"
         )}
      else
        socket = assign(socket, :upload_status, :processing)

        # Process JSON files directly through batch ingestion
        socket = process_json_files(socket, json_files)

        # Translate X12/EDI files in-process and ingest them locally
        socket = process_x12_files(socket, x12_files)

        {:noreply, socket}
      end
    end
  end

  # --- Batch History event handlers ---

  def handle_event("toggle_batch_history", _params, socket) do
    {:noreply, assign(socket, :show_batch_history, !socket.assigns.show_batch_history)}
  end

  def handle_event("toggle_batch_detail", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded_batch_ids

    updated =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_batch_ids, updated)}
  end

  def handle_event("toggle_batch_file_detail", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded_batch_file_ids

    updated =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_batch_file_ids, updated)}
  end

  def handle_event("filter_batch_risk", %{"level" => level}, socket) do
    current = socket.assigns.batch_risk_filter
    new_filter = if current == level, do: nil, else: level
    {:noreply, assign(socket, :batch_risk_filter, new_filter)}
  end

  def handle_event("refresh_batch_history", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_history, load_batch_history())
     |> put_flash(:info, "Batch history refreshed")}
  end

  def handle_event("clear_batch_history", _params, socket) do
    Claims.clear_batch_history()

    {:noreply,
     socket
     |> assign(:batch_history, [])
     |> assign(:expanded_batch_ids, MapSet.new())
     |> assign(:expanded_batch_file_ids, MapSet.new())
     |> put_flash(:info, "Job history cleared")}
  end

  def handle_event("dismiss_batch", %{"id" => id}, socket) do
    batch_id = String.to_integer(id)

    {:noreply,
     socket
     |> assign(:batch_history, Enum.reject(socket.assigns.batch_history, &(&1.id == batch_id)))
     |> assign(:expanded_batch_ids, MapSet.delete(socket.assigns.expanded_batch_ids, batch_id))}
  end

  defp classify_files(files) do
    Enum.reduce(files, {[], [], []}, fn {filename, content}, {json, x12, zip} ->
      ext = filename |> Path.extname() |> String.downcase()

      case ext do
        ".json" -> {[{filename, content} | json], x12, zip}
        ".x12" -> {json, [{filename, content} | x12], zip}
        ".edi" -> {json, [{filename, content} | x12], zip}
        ".zip" -> {json, x12, [{filename, content} | zip]}
        _ -> {json, x12, zip}
      end
    end)
  end

  defp extract_and_classify_zips(zip_files) do
    Enum.reduce(zip_files, {[], []}, fn {_zip_name, content}, {json_acc, x12_acc} ->
      case :zip.unzip(content, [:memory]) do
        {:ok, entries} ->
          Enum.reduce(entries, {json_acc, x12_acc}, fn {name, data}, {j, x} ->
            filename = to_string(name)

            case Path.safe_relative(filename) do
              {:ok, safe_name} ->
                ext = safe_name |> Path.extname() |> String.downcase()

                case ext do
                  ".json" -> {[{safe_name, data} | j], x}
                  ".x12" -> {j, [{safe_name, data} | x]}
                  ".edi" -> {j, [{safe_name, data} | x]}
                  _ -> {j, x}
                end

              :error ->
                require Logger
                Logger.warning("ZIP entry rejected (path traversal): #{inspect(filename)}")
                {j, x}
            end
          end)

        {:error, _} ->
          {json_acc, x12_acc}
      end
    end)
  end

  defp process_json_files(socket, []), do: socket

  defp process_json_files(socket, json_files) do
    batch_id = Ecto.UUID.generate()

    timestamp =
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/New_York")
      |> Calendar.strftime("%b %d, %Y %I:%M %p %Z")

    claims =
      Enum.flat_map(json_files, fn {filename, content} ->
        case Jason.decode(content) do
          {:ok, claim} -> [%{"filename" => filename, "claim" => claim}]
          {:error, _} -> []
        end
      end)

    if claims != [] do
      params = %{
        "batch_id" => batch_id,
        "batch_name" => "Manual Upload - #{timestamp}",
        "source" => "manual_upload",
        "claims" => claims
      }

      case Claims.ingest_batch(params) do
        {:ok, batch} ->
          new_entry = build_batch_entry(batch)

          socket
          |> assign(:upload_status, :done)
          |> assign(:upload_message, "#{length(claims)} JSON claim(s) submitted for evaluation.")
          |> assign(:batch_history, [new_entry | socket.assigns.batch_history])

        {:error, reason} ->
          socket
          |> assign(:upload_status, :error)
          |> assign(
            :upload_message,
            (socket.assigns.upload_message || "") <>
              " JSON ingestion error: #{inspect(reason)}"
          )
      end
    else
      socket
      |> assign(:upload_status, :error)
      |> assign(
        :upload_message,
        (socket.assigns.upload_message || "") <>
          " No valid JSON claims found in uploaded files."
      )
    end
  end

  defp process_x12_files(socket, []), do: socket

  defp process_x12_files(socket, x12_files) do
    batch_id = Ecto.UUID.generate()

    timestamp =
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/New_York")
      |> Calendar.strftime("%b %d, %Y %I:%M %p %Z")

    {claims, failures} =
      Enum.reduce(x12_files, {[], []}, fn file, {claims_acc, failures_acc} ->
        {file_claims, file_failures} = translate_x12_file(file)
        {claims_acc ++ file_claims, failures_acc ++ file_failures}
      end)

    prior = socket.assigns.upload_message
    failure_suffix = format_translation_failures(failures)

    if claims == [] do
      base = "X12/EDI translation produced no claims."

      socket
      |> assign(:upload_status, :error)
      |> assign(
        :upload_message,
        if(prior,
          do: "#{prior} #{base}#{failure_suffix}",
          else: "#{base}#{failure_suffix}"
        )
      )
    else
      params = %{
        "batch_id" => batch_id,
        "batch_name" => "Manual Upload - #{timestamp}",
        "source" => "manual_upload",
        "claims" => claims
      }

      case Claims.ingest_batch(params) do
        {:ok, batch} ->
          new_entry = build_batch_entry(batch)
          base = "#{length(claims)} X12/EDI claim(s) translated and submitted for evaluation."
          message = "#{base}#{failure_suffix}"

          socket
          |> assign(:upload_status, :done)
          |> assign(:upload_message, if(prior, do: "#{prior} #{message}", else: message))
          |> assign(:batch_history, [new_entry | socket.assigns.batch_history])

        {:error, reason} ->
          socket
          |> assign(:upload_status, :error)
          |> assign(
            :upload_message,
            if(prior,
              do: "#{prior} X12/EDI ingestion error: #{inspect(reason)}",
              else: "X12/EDI ingestion error: #{inspect(reason)}"
            )
          )
      end
    end
  end

  defp translate_x12_file({filename, content}) do
    # Pre-split files that have multiple GS/ST transaction sets in one envelope
    case ClaimSplitter.split_transaction_sets(content) do
      {:ok, nil} ->
        # Single transaction set — proceed with normal per-claim splitting
        translate_x12_single({filename, content})

      {:ok, ts_parts} ->
        # Multiple transaction sets — translate each independently
        Enum.reduce(ts_parts, {[], []}, fn ts_content, {claims_acc, failures_acc} ->
          {file_claims, file_failures} = translate_x12_single({filename, ts_content})
          {claims_acc ++ file_claims, failures_acc ++ file_failures}
        end)

      {:error, reason} ->
        {[], ["#{filename}: #{reason}"]}
    end
  end

  defp translate_x12_single({filename, content}) do
    case ClaimSplitter.split_claims_to_x12(content) do
      {:ok, nil} ->
        case translate_x12(content) do
          {:ok, claim} ->
            {[%{"filename" => to_json_filename(filename), "claim" => claim}], []}

          {:error, reason} ->
            {[], ["#{filename}: #{reason}"]}
        end

      {:ok, parts} when is_list(parts) ->
        Enum.reduce(parts, {[], []}, fn %{claim_id: cid, x12_content: cx12},
                                        {claims_acc, failures_acc} ->
          case translate_x12(cx12) do
            {:ok, claim} ->
              {claims_acc ++ [%{"filename" => to_split_filename(filename, cid), "claim" => claim}],
               failures_acc}

            {:error, reason} ->
              {claims_acc, failures_acc ++ ["#{filename} (claim #{cid}): #{reason}"]}
          end
        end)

      {:error, reason} ->
        {[], ["#{filename}: #{reason}"]}
    end
  end

  defp format_translation_failures([]), do: ""

  defp format_translation_failures(failures) do
    shown = failures |> Enum.take(3) |> Enum.join(" | ")
    more_count = max(length(failures) - 3, 0)

    more_text =
      if more_count > 0 do
        " (and #{more_count} more)"
      else
        ""
      end

    " Translation issues: #{shown}#{more_text}"
  end

  defp translate_x12(x12_content) do
    with {:ok, flat_json} <- Converter.convert_content(x12_content),
         {:ok, semantic} <- SegmentMapper.map_from_json(flat_json) do
      {:ok, semantic}
    end
  end

  defp to_json_filename(filename) do
    Path.rootname(filename) <> ".json"
  end

  defp to_split_filename(filename, claim_id) do
    "#{Path.rootname(filename)}_#{claim_id}.json"
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

  # --- Batch History helpers ---

  defp load_batch_history do
    Claims.list_recent_batches(20)
    |> Enum.map(&build_batch_entry/1)
  end

  defp build_batch_entry(batch) do
    files = Claims.list_files_for_batch(batch.id)

    files_with_details =
      Enum.map(files, fn f ->
        report = f.json_output || %{}

        matched_results =
          (report["results"] || [])
          |> Enum.filter(& &1["resultMatched"])
          |> Enum.map(fn r ->
            %{
              rule: r["resultRuleName"],
              detail: r["resultDetails"],
              action: action_label(r["resultAction"])
            }
          end)

        %{
          id: f.id,
          filename: normalize_filename(f.filename),
          status: f.status,
          risk: report["overallRisk"] || "N/A",
          matched_rules: report["matchedRules"] || 0,
          weighted_score: report["weightedScore"] || 0,
          matched_results: matched_results
        }
      end)

    %{
      id: batch.id,
      batch_id: batch.batch_id,
      batch_name: batch.batch_name,
      source: batch.source,
      status: batch.status,
      file_count: batch.file_count,
      inserted_at: batch.inserted_at,
      completed_at: batch.completed_at,
      files: files_with_details
    }
  end

  defp merge_batch_update(socket, batch_id) do
    case Claims.get_batch_by_batch_id(batch_id) do
      nil ->
        socket

      batch ->
        updated = build_batch_entry(batch)
        history = socket.assigns.batch_history

        new_history =
          if Enum.any?(history, &(&1.batch_id == batch_id)) do
            Enum.map(history, fn b -> if b.batch_id == batch_id, do: updated, else: b end)
          else
            [updated | history]
          end

        assign(socket, :batch_history, new_history)
    end
  end

  defp file_type_color(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".json" -> "bg-green-500"
      ".x12" -> "bg-purple-500"
      ".edi" -> "bg-purple-500"
      ".zip" -> "bg-orange-500"
      _ -> "bg-gray-500"
    end
  end

  defp file_type_badge(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".json" -> "bg-green-100 text-green-800"
      ".x12" -> "bg-purple-100 text-purple-800"
      ".edi" -> "bg-purple-100 text-purple-800"
      ".zip" -> "bg-orange-100 text-orange-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp file_type_label(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".json" -> "JSON"
      ".x12" -> "X12"
      ".edi" -> "EDI"
      ".zip" -> "ZIP"
      ext -> ext
    end
  end

  defp normalize_filename(filename) do
    case Path.extname(filename) do
      ext when ext in [".x12", ".edi", ".X12", ".EDI"] ->
        Path.rootname(filename) <> ".json"

      "" ->
        filename <> ".json"

      _ ->
        filename
    end
  end

  defp upload_error_to_string(:too_large), do: "File is too large (max 10 MB)."

  defp upload_error_to_string(:not_accepted),
    do: "File type not accepted. Allowed: .json, .x12, .edi, .zip"

  defp upload_error_to_string(:too_many_files), do: "Too many files selected (max 100)."
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp action_label(%{"tag" => "RejectClaim'"}), do: "REJECT"
  defp action_label(%{"tag" => "FlagFraud'"}), do: "FRAUD"
  defp action_label(%{"tag" => "RequireReview'"}), do: "REVIEW"
  defp action_label(%{"tag" => "CompositeAction'", "contents" => [first | _]}),
    do: action_label(first)
  defp action_label(_), do: "UNKNOWN"
end
