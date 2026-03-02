defmodule X12FraudWebWeb.RuleCatalogueLive.Index do
  use X12FraudWebWeb, :live_view

  alias X12FraudWeb.Claims

  @impl true
  def mount(_params, _session, socket) do
    entries = safe_list_entries()

    {:ok,
     socket
     |> assign(:entries, entries)
     |> assign(:filter_type, "All")
     |> assign(:show_add_form, false)
     |> assign(:new_name, "")
     |> assign(:new_description, "")
     |> assign(:new_type, "BA Rule")
     |> assign(:new_db_access, false)
     |> assign(:form_error, nil)
     |> assign(:redundancy_warning, [])
     |> assign(:pending_save_attrs, nil)}
  end

  @impl true
  def handle_event("set_filter", %{"type" => type}, socket) do
    {:noreply, assign(socket, :filter_type, type)}
  end

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)
     |> assign(:form_error, nil)
     |> assign(:redundancy_warning, [])
     |> assign(:pending_save_attrs, nil)
     |> assign(:new_name, "")
     |> assign(:new_description, "")
     |> assign(:new_type, "BA Rule")
     |> assign(:new_db_access, false)}
  end

  @impl true
  def handle_event("update_new_entry", %{"entry" => params}, socket) do
    {:noreply,
     socket
     |> assign(:new_name, Map.get(params, "name", ""))
     |> assign(:new_description, Map.get(params, "description", ""))
     |> assign(:new_type, Map.get(params, "type", "BA Rule"))
     |> assign(:new_db_access, Map.get(params, "db_access") == "true")
     |> assign(:form_error, nil)
     |> assign(:redundancy_warning, [])}
  end

  @impl true
  def handle_event("save_new_entry", %{"entry" => params}, socket) do
    name = String.trim(Map.get(params, "name", ""))
    description = String.trim(Map.get(params, "description", ""))
    entry_type = Map.get(params, "type", "BA Rule")
    db_access = Map.get(params, "db_access") == "true"

    if name == "" do
      {:noreply, assign(socket, :form_error, "Name is required.")}
    else
      similar = Claims.find_similar_catalogue_entries(name)

      if similar != [] do
        attrs = %{
          name: name,
          description: description,
          entry_type: entry_type,
          status: "Active",
          editable: true,
          removable: true,
          redundant: true,
          db_access: db_access
        }

        {:noreply,
         socket
         |> assign(:redundancy_warning, similar)
         |> assign(:pending_save_attrs, attrs)}
      else
        do_save_entry(socket, %{
          name: name,
          description: description,
          entry_type: entry_type,
          status: "Active",
          editable: true,
          removable: true,
          redundant: false,
          db_access: db_access
        })
      end
    end
  end

  @impl true
  def handle_event("confirm_save_redundant", _params, socket) do
    case socket.assigns.pending_save_attrs do
      nil -> {:noreply, assign(socket, :form_error, "Nothing to save.")}
      attrs -> do_save_entry(socket, attrs)
    end
  end

  @impl true
  def handle_event("dismiss_redundancy_warning", _params, socket) do
    {:noreply,
     socket
     |> assign(:redundancy_warning, [])
     |> assign(:pending_save_attrs, nil)}
  end

  @impl true
  def handle_event("toggle_status", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = entry <- Claims.get_catalogue_entry(entry_id),
         {:ok, _updated} <- Claims.toggle_catalogue_status(entry) do
      {:noreply, socket |> refresh_entries() |> assign(:form_error, nil)}
    else
      _ -> {:noreply, assign(socket, :form_error, "Could not update status.")}
    end
  end

  @impl true
  def handle_event("delete_entry", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = entry <- Claims.get_catalogue_entry(entry_id) do
      if entry.removable do
        case Claims.delete_catalogue_entry(entry) do
          {:ok, _} ->
            {:noreply,
             socket
             |> refresh_entries()
             |> assign(:form_error, nil)
             |> put_flash(:info, "Entry removed from catalogue.")}

          {:error, _} ->
            {:noreply, assign(socket, :form_error, "Could not remove entry.")}
        end
      else
        {:noreply, assign(socket, :form_error, "This entry cannot be removed.")}
      end
    else
      _ -> {:noreply, assign(socket, :form_error, "Could not find entry.")}
    end
  end

  # --- Private helpers ---

  defp do_save_entry(socket, attrs) do
    case Claims.create_catalogue_entry(attrs) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> refresh_entries()
         |> assign(:show_add_form, false)
         |> assign(:new_name, "")
         |> assign(:new_description, "")
         |> assign(:new_type, "BA Rule")
         |> assign(:new_db_access, false)
         |> assign(:form_error, nil)
         |> assign(:redundancy_warning, [])
         |> assign(:pending_save_attrs, nil)
         |> put_flash(:info, "Entry added to catalogue.")}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
          |> Enum.join(", ")

        {:noreply, assign(socket, :form_error, "Could not save: #{message}")}
    end
  end

  defp refresh_entries(socket) do
    assign(socket, :entries, safe_list_entries())
  end

  defp safe_list_entries do
    Claims.list_catalogue_entries()
  rescue
    _ -> []
  end

  defp filtered_entries(entries, "All"), do: entries
  defp filtered_entries(entries, type), do: Enum.filter(entries, &(&1.entry_type == type))

  defp entry_counts(entries) do
    %{
      total: length(entries),
      default: Enum.count(entries, &(&1.entry_type == "Default Rule")),
      ba: Enum.count(entries, &(&1.entry_type == "BA Rule")),
      ml: Enum.count(entries, &(&1.entry_type == "ML Model")),
      active: Enum.count(entries, &(&1.status == "Active")),
      redundant: Enum.count(entries, & &1.redundant)
    }
  end
end
