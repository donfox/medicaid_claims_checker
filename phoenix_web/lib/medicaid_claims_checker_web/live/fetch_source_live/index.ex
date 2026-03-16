defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.Index do
  use MedicaidClaimsCheckerWeb, :live_view

  alias MedicaidClaimsChecker.Ingestion

  @impl true
  def mount(_params, _session, socket) do
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
     |> assign(:source_username, "")}
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
end
