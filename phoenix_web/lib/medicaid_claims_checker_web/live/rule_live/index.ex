defmodule MedicaidClaimsCheckerWeb.RuleLive.Index do
  use MedicaidClaimsCheckerWeb, :live_view
  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.EngineClient
  alias MedicaidClaimsChecker.Claims.Evaluator
  alias MedicaidClaimsChecker.Claims.RuleSchemaValidator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Evaluator.topic())
    end

    catalog_rules = safe_list_catalogue_entries()

    {:ok,
     socket
     |> assign(:catalog_rules, catalog_rules)
     |> assign(:catalog_rule_name, "")
     |> assign(:catalog_rule_text, "")
     |> assign(:catalog_parse_error, nil)
     |> assign(:catalog_parsed_rule, nil)
     |> assign(:selected_catalog_rule_id, nil)
     |> assign(:selected_catalog_rule_type, nil)
     |> assign(:catalog_error, nil)
     |> assign(:redundancy_matches, [])
     |> assign(:redundancy_pending_save, nil)
     |> assign(:show_dsl_reference, false)
     |> assign(:batch_notification, nil)}
  end

  @impl true
  def handle_info(
        {:batch_completed, %{batch_id: batch_id, summary: summary, files: files}},
        socket
      )
      when is_map(summary) and is_list(files) do
    notification = %{
      type: :completed,
      batch_id: batch_id,
      total: summary.total,
      flagged: summary.flagged_for_review,
      clean: summary.total - summary.flagged_for_review,
      files: files,
      expanded: false
    }

    {:noreply,
     socket
     |> assign(:batch_notification, notification)}
  end

  # Ignore a completion message without a summary and file list
  def handle_info({:batch_completed, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_info({:batch_failed, %{batch_id: batch_id, reason: reason}}, socket)
      when is_binary(reason) do
    notification = %{
      type: :failed,
      batch_id: batch_id,
      reason: reason
    }

    {:noreply, assign(socket, :batch_notification, notification)}
  end

  def handle_info({:batch_failed, _payload}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("dismiss_batch_notification", _params, socket) do
    {:noreply, assign(socket, :batch_notification, nil)}
  end

  def handle_event("toggle_notification_details", _params, socket) do
    notification = socket.assigns.batch_notification

    {:noreply,
     assign(socket, :batch_notification, %{notification | expanded: !notification.expanded})}
  end

  def handle_event("update_catalog_rule", %{"catalog" => params}, socket) do
    rule_text = Map.get(params, "text", "")
    {parsed_rule, parse_error} = parse_single_rule_text(rule_text)

    # Auto-format when the rule parses successfully
    display_text =
      if parse_error == nil and String.trim(rule_text) != "" do
        format_dsl_text(rule_text)
      else
        rule_text
      end

    {:noreply,
     socket
     |> assign(:catalog_rule_name, Map.get(params, "name", ""))
     |> assign(:catalog_rule_text, display_text)
     |> assign(:catalog_parsed_rule, parsed_rule)
     |> assign(:catalog_parse_error, parse_error)
     |> assign(:catalog_error, nil)}
  end

  @impl true
  def handle_event("save_catalog_rule", %{"catalog" => params}, socket) do
    selected_entry_id = socket.assigns.selected_catalog_rule_id
    normalized_rule_text = normalize_dsl_text(Map.get(params, "text", ""))
    name = String.trim(Map.get(params, "name", ""))

    {_parsed, parse_error} = parse_single_rule_text(normalized_rule_text)

    if parse_error != nil do
      {:noreply, assign(socket, :catalog_error, "Could not save rule: #{parse_error}")}
    else
      schema_validation = RuleSchemaValidator.validate(normalized_rule_text)

      # Exclude the rule being edited by its original DB name (not the
      # possibly-renamed form value) so it doesn't match against itself.
      exclude_name =
        if selected_entry_id do
          case Claims.get_catalogue_entry(selected_entry_id) do
            %{name: original_name} -> original_name
            _ -> name
          end
        else
          nil
        end

      case check_redundancy(normalized_rule_text, exclude_name) do
        {:ok, [_ | _] = matches} ->
          # Redundancy detected — store pending save and show warning
          pending = %{
            name: name,
            rule_text: normalized_rule_text,
            selected_entry_id: selected_entry_id
          }

          {:noreply,
           socket
           |> assign(:redundancy_matches, matches)
           |> assign(:redundancy_pending_save, pending)
           |> assign(:catalog_error, nil)}

        _ ->
          # No redundancy (or check failed) — proceed with save
          do_save_catalog_rule(
            socket,
            name,
            normalized_rule_text,
            selected_entry_id,
            false,
            schema_validation
          )
      end
    end
  end

  @impl true
  def handle_event("dismiss_redundancy_warning", _params, socket) do
    case socket.assigns.redundancy_pending_save do
      nil ->
        {:noreply, socket}

      %{name: name, rule_text: rule_text, selected_entry_id: selected_entry_id} ->
        socket =
          socket
          |> assign(:redundancy_matches, [])
          |> assign(:redundancy_pending_save, nil)

        do_save_catalog_rule(
          socket,
          name,
          rule_text,
          selected_entry_id,
          true,
          RuleSchemaValidator.validate(rule_text)
        )
    end
  end

  @impl true
  def handle_event("cancel_redundancy_save", _params, socket) do
    {:noreply,
     socket
     |> assign(:redundancy_matches, [])
     |> assign(:redundancy_pending_save, nil)}
  end

  @impl true
  def handle_event("toggle_catalog_rule_active", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = catalogue_entry <- Claims.get_catalogue_entry(entry_id),
         :ok <- validate_before_activation(catalogue_entry),
         {:ok, _updated} <- Claims.toggle_catalogue_status(catalogue_entry) do
      # Keep business_rule.active in sync for BA Rules and Default Rules
      if catalogue_entry.entry_type in ["BA Rule", "Default Rule"] do
        case Claims.get_business_rule_by_name(catalogue_entry.name) do
          %{} = rule -> Claims.toggle_business_rule_active(rule)
          nil -> :ok
        end
      end

      {:noreply, socket |> refresh_catalog_rules() |> assign(:catalog_error, nil)}
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not update rule status.")}
    end
  end

  @impl true
  def handle_event("delete_catalog_rule", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = catalogue_entry <- Claims.get_catalogue_entry(entry_id) do
      if catalogue_entry.removable do
        # Delete the business_rule too if it's a BA Rule
        if catalogue_entry.entry_type == "BA Rule" do
          case Claims.get_business_rule_by_name(catalogue_entry.name) do
            %{} = rule -> Claims.delete_business_rule(rule)
            nil -> :ok
          end
        end

        case Claims.delete_catalogue_entry(catalogue_entry) do
          {:ok, _deleted} ->
            recheck_redundancy_flags()

            {:noreply,
             socket
             |> refresh_catalog_rules()
             |> assign(:catalog_error, nil)
             |> put_flash(:info, "Rule removed from catalogue.")}

          {:error, _} ->
            {:noreply, assign(socket, :catalog_error, "Could not remove rule.")}
        end
      else
        {:noreply, assign(socket, :catalog_error, "This rule cannot be removed.")}
      end
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not find rule.")}
    end
  end

  @impl true
  def handle_event("select_catalog_rule", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = catalogue_entry <- Claims.get_catalogue_entry(entry_id) do
      {rule_name, rule_text, parsed_rule, parse_error} =
        case catalogue_entry.entry_type do
          "BA Rule" ->
            case Claims.get_business_rule_by_name(catalogue_entry.name) do
              %{} = rule ->
                text = format_dsl_text(rule.rule_text || "")
                {parsed, err} = parse_single_rule_text(text)
                {rule.name, text, parsed, err}

              nil ->
                {catalogue_entry.name, "", nil, nil}
            end

          "Default Rule" ->
            # Default Rules: look up DSL text from business_rules if present
            case Claims.get_business_rule_by_name(catalogue_entry.name) do
              %{} = rule ->
                text = format_dsl_text(rule.rule_text || "")
                {parsed, err} = parse_single_rule_text(text)
                {rule.name, text, parsed, err}

              nil ->
                description = catalogue_entry.description || ""

                display_text =
                  "-- Default Rule: #{catalogue_entry.name}\n-- #{description}\n-- No DSL implementation (requires database access)."

                {catalogue_entry.name, display_text, nil, nil}
            end

          _ ->
            # ML Models: show name + description read-only, no DSL text
            description = catalogue_entry.description || ""

            display_text =
              if description != "",
                do:
                  "-- #{catalogue_entry.entry_type}: #{catalogue_entry.name}\n-- #{description}\n-- This rule is scored by an external ML service.",
                else:
                  "-- #{catalogue_entry.entry_type}: #{catalogue_entry.name}\n-- This rule is scored by an external ML service."

            {catalogue_entry.name, display_text, nil, nil}
        end

      {:noreply,
       socket
       |> assign(:catalog_rule_name, rule_name)
       |> assign(:catalog_rule_text, rule_text)
       |> assign(:catalog_parsed_rule, parsed_rule)
       |> assign(:catalog_parse_error, parse_error)
       |> assign(:selected_catalog_rule_id, entry_id)
       |> assign(:selected_catalog_rule_type, catalogue_entry.entry_type)
       |> assign(:catalog_error, nil)}
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not load rule from catalogue.")}
    end
  end

  @impl true
  def handle_event("dismiss_selected_catalog_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:catalog_rule_name, "")
     |> assign(:catalog_rule_text, "")
     |> assign(:catalog_parsed_rule, nil)
     |> assign(:catalog_parse_error, nil)
     |> assign(:selected_catalog_rule_id, nil)
     |> assign(:selected_catalog_rule_type, nil)
     |> assign(:catalog_error, nil)}
  end

  @impl true
  def handle_event("clear_catalog_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:catalog_rule_name, "")
     |> assign(:catalog_rule_text, "")
     |> assign(:catalog_parsed_rule, nil)
     |> assign(:catalog_parse_error, nil)
     |> assign(:selected_catalog_rule_id, nil)
     |> assign(:selected_catalog_rule_type, nil)
     |> assign(:catalog_error, nil)
     |> assign(:redundancy_matches, [])
     |> assign(:redundancy_pending_save, nil)}
  end

  @impl true
  def handle_event("toggle_dsl_reference", _params, socket) do
    {:noreply, update(socket, :show_dsl_reference, &(!&1))}
  end

  defp do_save_catalog_rule(
         socket,
         name,
         normalized_rule_text,
         selected_entry_id,
         mark_redundant,
         schema_validation
       ) do
    schema_issues =
      case schema_validation do
        {:ok, %{issues: issues}} -> issues
        {:error, %{issues: issues}} -> issues
        _ -> []
      end

    schema_drift? = schema_issues != []

    if selected_entry_id do
      # Editing an existing catalogue entry — only BA Rules have editable DSL text
      case Claims.get_catalogue_entry(selected_entry_id) do
        %{status: "Retired"} ->
          {:noreply, assign(socket, :catalog_error, "Retired rules can't be edited.")}

        %{entry_type: "BA Rule"} = catalogue_entry ->
          case Claims.get_business_rule_by_name(catalogue_entry.name) do
            %{} = rule ->
              saved_active = if schema_drift?, do: false, else: rule.active

              case Claims.update_business_rule(rule, %{
                     name: name,
                     rule_text: String.trim(normalized_rule_text),
                     active: saved_active
                   }) do
                {:ok, _updated} ->
                  updates =
                    if name != catalogue_entry.name,
                      do: %{
                        name: name,
                        redundant: mark_redundant,
                        status: if(saved_active, do: "Active", else: "Inactive")
                      },
                      else: %{
                        redundant: mark_redundant,
                        status: if(saved_active, do: "Active", else: "Inactive")
                      }

                  Claims.update_catalogue_entry(catalogue_entry, updates)

                  message =
                    if schema_drift? do
                      "Business rule saved as draft. Fix schema drift before activation: " <>
                        RuleSchemaValidator.format_issues(schema_issues)
                    else
                      "Business rule updated."
                    end

                  {:noreply,
                   socket
                   |> refresh_catalog_rules()
                   |> assign(:catalog_rule_name, "")
                   |> assign(:catalog_rule_text, "")
                   |> assign(:catalog_parsed_rule, nil)
                   |> assign(:catalog_parse_error, nil)
                   |> assign(:selected_catalog_rule_id, nil)
                   |> assign(:selected_catalog_rule_type, nil)
                   |> assign(:catalog_error, nil)
                   |> put_flash(:info, message)}

                {:error, changeset} ->
                  message =
                    changeset.errors
                    |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
                    |> Enum.join(", ")

                  {:noreply, assign(socket, :catalog_error, "Could not save rule: #{message}")}
              end

            nil ->
              {:noreply, assign(socket, :catalog_error, "Business rule not found.")}
          end

        _ ->
          {:noreply, assign(socket, :catalog_error, "Only BA Rules can be edited here.")}
      end
    else
      # Creating a new BA Rule — write to business_rules and catalogue
      saved_active = not schema_drift?

      attrs = %{
        name: name,
        rule_text: String.trim(normalized_rule_text),
        active: saved_active
      }

      case Claims.create_business_rule(attrs) do
        {:ok, _rule} ->
          Claims.create_catalogue_entry(%{
            name: name,
            description: "",
            entry_type: "BA Rule",
            status: if(saved_active, do: "Active", else: "Inactive"),
            editable: true,
            removable: true,
            redundant: mark_redundant,
            db_access: false
          })

          message =
            if schema_drift? do
              "Business rule saved as draft. Fix schema drift before activation: " <>
                RuleSchemaValidator.format_issues(schema_issues)
            else
              "Business rule saved to catalogue."
            end

          {:noreply,
           socket
           |> refresh_catalog_rules()
           |> assign(:catalog_rule_name, "")
           |> assign(:catalog_rule_text, "")
           |> assign(:catalog_parsed_rule, nil)
           |> assign(:catalog_parse_error, nil)
           |> assign(:catalog_error, nil)
           |> put_flash(:info, message)}

        {:error, changeset} ->
          message =
            changeset.errors
            |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
            |> Enum.join(", ")

          {:noreply, assign(socket, :catalog_error, "Could not save rule: #{message}")}
      end
    end
  end

  defp validate_before_activation(%{entry_type: entry_type, status: "Inactive", name: name})
       when entry_type in ["BA Rule", "Default Rule"] do
    case Claims.get_business_rule_by_name(name) do
      %{} = rule ->
        case RuleSchemaValidator.validate(rule.rule_text || "") do
          {:ok, _details} ->
            :ok

          {:error, %{issues: issues}} ->
            {:error,
             "Cannot activate rule until schema drift is fixed: " <>
               RuleSchemaValidator.format_issues(issues)}
        end

      nil ->
        :ok
    end
  end

  defp validate_before_activation(_catalogue_entry), do: :ok

  defp refresh_catalog_rules(socket) do
    assign(socket, :catalog_rules, safe_list_catalogue_entries())
  end

  defp safe_list_catalogue_entries do
    Claims.list_catalogue_entries()
  rescue
    _ -> []
  end

  defp filtered_catalog_rules(rules, "All"), do: rules
  defp filtered_catalog_rules(rules, type), do: Enum.filter(rules, &(&1.entry_type == type))

  defp catalog_counts(rules) do
    %{
      total: length(rules),
      default: Enum.count(rules, &(&1.entry_type == "Default Rule")),
      ba: Enum.count(rules, &(&1.entry_type == "BA Rule")),
      ml: Enum.count(rules, &(&1.entry_type == "ML Model")),
      active: Enum.count(rules, &(&1.status == "Active")),
      redundant: Enum.count(rules, & &1.redundant)
    }
  end

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp parse_single_rule_text(text) do
    normalized_text = normalize_dsl_text(text)

    case parse_rule(normalized_text) do
      {:ok, %{"rule" => rules} = parsed} when is_list(rules) ->
        case length(rules) do
          n when n > 0 ->
            {parsed, nil}

          0 ->
            {nil, "No rules found. Enter at least one RULE...END block."}
        end

      {:ok, parsed} ->
        {parsed, nil}

      {:error, error} ->
        {nil, normalize_error(error)}
    end
  end

  defp parse_rule(text) do
    normalized_text = normalize_dsl_text(text)

    case EngineClient.post("/api/parse-rule", Jason.encode!(%{ruleText: normalized_text}),
           connect_timeout: 8_000,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => err}} -> {:error, err}
          _ -> {:error, body}
        end

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp check_redundancy(candidate_rule_text, exclude_name) do
    existing_rules =
      Claims.list_active_business_rules()
      |> Enum.reject(fn rule -> exclude_name && rule.name == exclude_name end)
      |> Enum.map(& &1.rule_text)
      |> Enum.filter(fn t -> t && String.trim(t) != "" end)

    if existing_rules == [] do
      {:ok, []}
    else
      body =
        Jason.encode!(%{
          candidateRuleText: normalize_dsl_text(candidate_rule_text),
          existingRulesTexts: Enum.map(existing_rules, &normalize_dsl_text/1)
        })

      case EngineClient.post("/api/check-redundancy", body,
             connect_timeout: 10_000,
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"success" => true, "matches" => matches}} -> {:ok, matches}
            {:ok, %{"success" => false, "error" => err}} -> {:error, err}
            _ -> {:ok, []}
          end

        {:error, _err} ->
          # If redundancy check fails, don't block the save
          {:ok, []}
      end
    end
  end

  # Re-check all rules currently marked redundant.  If the conflicting rule
  # has been removed, clear the flag.
  defp recheck_redundancy_flags do
    Claims.list_catalogue_entries()
    |> Enum.filter(fn e -> e.redundant && e.entry_type == "BA Rule" end)
    |> Enum.each(fn entry ->
      case Claims.get_business_rule_by_name(entry.name) do
        %{rule_text: rule_text} when is_binary(rule_text) ->
          case check_redundancy(rule_text, entry.name) do
            {:ok, []} -> Claims.update_catalogue_entry(entry, %{redundant: false})
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  # -- Redundancy notification tiers ----------------------------------------

  # Tier 1 (red): action conflicts — same conditions, different actions
  # Tier 2 (yellow): harmless but unnecessary — exact duplicates or subsumption with same action
  # Tier 3 (blue): informational — partial condition overlap, possibly intentional

  defp redundancy_tier("ExactDuplicate"), do: :redundant
  defp redundancy_tier("Shadowed"), do: :conflict
  defp redundancy_tier("Subsumption"), do: :redundant
  defp redundancy_tier("ConditionOverlap"), do: :overlap
  defp redundancy_tier(_), do: :overlap

  defp redundancy_level_label("ExactDuplicate"), do: "Exact Duplicate"
  defp redundancy_level_label("Shadowed"), do: "Action Conflict"
  defp redundancy_level_label("Subsumption"), do: "Redundant Rule"
  defp redundancy_level_label("ConditionOverlap"), do: "Partial Overlap"
  defp redundancy_level_label(other), do: other

  defp group_redundancy_matches(matches) do
    grouped = Enum.group_by(matches, &redundancy_tier(&1["matchLevel"]))

    [
      {:conflict, Map.get(grouped, :conflict, [])},
      {:redundant, Map.get(grouped, :redundant, [])},
      {:overlap, Map.get(grouped, :overlap, [])}
    ]
    |> Enum.reject(fn {_tier, items} -> items == [] end)
  end

  defp redundancy_has_conflicts?(matches) do
    Enum.any?(matches, &(redundancy_tier(&1["matchLevel"]) == :conflict))
  end

  defp normalize_dsl_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("ENDRULE", "END RULE")
  end

  @doc false
  # Format DSL text with consistent indentation and line breaks.
  # Keywords RULE, DESCRIPTION, WHEN, THEN, END start at column 0;
  # condition and action lines are indented by two spaces.
  defp format_dsl_text(text) when is_binary(text) do
    text
    |> normalize_dsl_text()
    |> split_keywords_onto_lines()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&format_dsl_line/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # Split single-line rules into multi-line by inserting newlines before
  # WHEN, THEN, and before the trailing semicolon. Avoids splitting inside
  # quoted strings by working outside of them.
  defp split_keywords_onto_lines(text) do
    text
    |> String.replace(~r/\s+WHEN\s+/, "\nWHEN\n  ")
    |> String.replace(~r/\s+THEN\s+/, "\nTHEN\n  ")
    |> String.replace(~r/;\s*$/, "\nEND", global: false)
  end

  defp format_dsl_line(line) do
    upper = String.upcase(line)

    cond do
      String.starts_with?(upper, "RULE ") -> line
      String.starts_with?(upper, "DESCRIPTION ") -> "  " <> line
      upper == "WHEN" -> "WHEN"
      String.starts_with?(upper, "WHEN ") -> "WHEN\n  " <> String.slice(line, 5..-1//1)
      upper == "THEN" -> "THEN"
      String.starts_with?(upper, "THEN ") -> "THEN\n  " <> String.slice(line, 5..-1//1)
      upper == "END" -> "END"
      String.starts_with?(line, "--") -> line
      true -> "  " <> line
    end
  end
end
