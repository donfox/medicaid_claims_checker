defmodule X12FraudWebWeb.RuleLive.Index do
  use X12FraudWebWeb, :live_view
  import X12FraudWebWeb.Components.RuleComponents
  alias X12FraudWeb.Claims
  alias X12FraudWebWeb.RuleLive.PayloadBuilder

  @impl true
  def mount(_params, _session, socket) do
    default_rule = get_default_rule()
    catalog_rules = safe_list_catalogue_entries()

    {batch_parsed_rules, batch_parse_error} =
      case parse_rule(default_rule) do
        {:ok, %{"rule" => rules}} when is_list(rules) and length(rules) > 0 -> {rules, nil}
        {:ok, %{"success" => false, "error" => err}} -> {nil, err}
        {:ok, %{"error" => err}} -> {nil, err}
        {:ok, _} -> {nil, "Could not validate rules"}
        {:error, error} -> {nil, normalize_error(error)}
      end

    {:ok,
     socket
     |> assign(:batch_rule_text, default_rule)
     |> assign(:batch_parsed_rules, batch_parsed_rules)
     |> assign(:batch_parse_error, batch_parse_error)
     |> assign(:batch_status, :idle)
     |> assign(:batch_results, [])
     |> assign(:batch_error, nil)
     |> assign(:batch_summary, nil)
     |> assign(:batch_show_matched_only, true)
     |> assign(:expanded_claims, MapSet.new())
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
     |> assign(:batch_filter, nil)
     |> allow_upload(:claim_files,
       accept: ~w(.json),
       max_entries: 100,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_event("update_catalog_rule", %{"catalog" => params}, socket) do
    rule_text = Map.get(params, "text", "")
    {parsed_rule, parse_error} = parse_single_rule_text(rule_text)

    {:noreply,
     socket
     |> assign(:catalog_rule_name, Map.get(params, "name", ""))
     |> assign(:catalog_rule_text, rule_text)
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
          do_save_catalog_rule(socket, name, normalized_rule_text, selected_entry_id, false)
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

        do_save_catalog_rule(socket, name, rule_text, selected_entry_id, true)
    end
  end

  @impl true
  def handle_event("cancel_redundancy_save", _params, socket) do
    {:noreply,
     socket
     |> assign(:redundancy_matches, [])
     |> assign(:redundancy_pending_save, nil)}
  end

  defp do_save_catalog_rule(socket, name, normalized_rule_text, selected_entry_id, mark_redundant) do
    if selected_entry_id do
      # Editing an existing catalogue entry — only BA Rules have editable DSL text
      case Claims.get_catalogue_entry(selected_entry_id) do
        %{entry_type: "BA Rule"} = catalogue_entry ->
          case Claims.get_business_rule_by_name(catalogue_entry.name) do
            %{} = rule ->
              case Claims.update_business_rule(rule, %{
                     name: name,
                     rule_text: String.trim(normalized_rule_text),
                     active: rule.active
                   }) do
                {:ok, _updated} ->
                  updates =
                    if name != catalogue_entry.name,
                      do: %{name: name, redundant: mark_redundant},
                      else: %{redundant: mark_redundant}

                  Claims.update_catalogue_entry(catalogue_entry, updates)

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
                   |> put_flash(:info, "Business rule updated.")}

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
      attrs = %{
        name: name,
        rule_text: String.trim(normalized_rule_text),
        active: true
      }

      case Claims.create_business_rule(attrs) do
        {:ok, _rule} ->
          Claims.create_catalogue_entry(%{
            name: name,
            description: "",
            entry_type: "BA Rule",
            status: "Active",
            editable: true,
            removable: true,
            redundant: mark_redundant,
            db_access: false
          })

          {:noreply,
           socket
           |> refresh_catalog_rules()
           |> assign(:catalog_rule_name, "")
           |> assign(:catalog_rule_text, "")
           |> assign(:catalog_parsed_rule, nil)
           |> assign(:catalog_parse_error, nil)
           |> assign(:catalog_error, nil)
           |> put_flash(:info, "Business rule saved to catalogue.")}

        {:error, changeset} ->
          message =
            changeset.errors
            |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
            |> Enum.join(", ")

          {:noreply, assign(socket, :catalog_error, "Could not save rule: #{message}")}
      end
    end
  end

  @impl true
  def handle_event("toggle_catalog_rule_active", %{"id" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %{} = catalogue_entry <- Claims.get_catalogue_entry(entry_id),
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
                display_text = "-- Default Rule: #{catalogue_entry.name}\n-- #{description}\n-- No DSL implementation (requires database access)."
                {catalogue_entry.name, display_text, nil, nil}
            end

          _ ->
            # ML Models: show name + description read-only, no DSL text
            description = catalogue_entry.description || ""
            display_text =
              if description != "",
                do: "-- #{catalogue_entry.entry_type}: #{catalogue_entry.name}\n-- #{description}\n-- This rule is scored by an external ML service.",
                else: "-- #{catalogue_entry.entry_type}: #{catalogue_entry.name}\n-- This rule is scored by an external ML service."

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
  def handle_event("update_batch_rule", %{"batch_rule" => %{"text" => text}}, socket) do
    {parsed_rules, parse_error} = parse_batch_rules(text)

    {:noreply,
     socket
     |> assign(:batch_rule_text, text)
     |> assign(:batch_parsed_rules, parsed_rules)
     |> assign(:batch_parse_error, parse_error)}
  end

  @impl true
  def handle_event("validate_uploads", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_claim_uploads", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.claim_files.entries, socket, fn entry, acc_socket ->
        cancel_upload(acc_socket, :claim_files, entry.ref)
      end)

    {:noreply,
     socket
     |> assign(:batch_status, :idle)
     |> assign(:batch_error, nil)}
  end

  @impl true
  def handle_event("clear_batch_rule", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_rule_text, "")
     |> assign(:batch_parsed_rules, [])
     |> assign(:batch_parse_error, nil)
     |> assign(:batch_status, :idle)
     |> assign(:batch_error, nil)}
  end

  @impl true
  def handle_event("toggle_batch_matched_only", _params, socket) do
    {:noreply, update(socket, :batch_show_matched_only, &(!&1))}
  end

  @impl true
  def handle_event("toggle_dsl_reference", _params, socket) do
    {:noreply, update(socket, :show_dsl_reference, &(!&1))}
  end

  @impl true
  def handle_event("filter_batch", %{"filter" => filter}, socket) do
    filter = if filter == "", do: nil, else: filter
    current = socket.assigns.batch_filter
    new_filter = if current == filter, do: nil, else: filter
    {:noreply, assign(socket, :batch_filter, new_filter)}
  end

  @impl true
  def handle_event("toggle_expand_all", _params, socket) do
    results = socket.assigns.batch_results
    all_indices = MapSet.new(Enum.map(results, & &1["claimIndex"]))

    new_expanded =
      if MapSet.equal?(socket.assigns.expanded_claims, all_indices),
        do: MapSet.new(),
        else: all_indices

    {:noreply, assign(socket, :expanded_claims, new_expanded)}
  end

  @impl true
  def handle_event("toggle_claim_details", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    expanded =
      if MapSet.member?(socket.assigns.expanded_claims, index),
        do: MapSet.delete(socket.assigns.expanded_claims, index),
        else: MapSet.put(socket.assigns.expanded_claims, index)

    {:noreply, assign(socket, :expanded_claims, expanded)}
  end

  @impl true
  def handle_event("download_results", _params, socket) do
    json_data = Jason.encode!(socket.assigns.batch_results, pretty: true)

    {:noreply,
     push_event(socket, "download", %{
       filename: "batch_results_#{Date.utc_today()}.json",
       data: json_data
     })}
  end

  @impl true
  def handle_event("process_batch", _params, socket) do
    {execution_rules_text, parsed_rules, parse_error} = batch_execution_rules(socket)

    if parse_error != nil or parsed_rules in [nil, []] do
      {:noreply,
       socket
       |> assign(:batch_status, :error)
       |> assign(:batch_error, "Fix rule syntax before running.")}
    else
      consumed =
        consume_uploaded_entries(socket, :claim_files, fn %{path: path}, entry ->
          {:ok, decode_claim_file(path, entry.client_name)}
        end)

      {file_errors, claims_with_names} =
        Enum.reduce(consumed, {[], []}, fn
          {:ok, {claim, filename}}, {errs, docs} -> {errs, [{claim, filename} | docs]}
          {:error, err}, {errs, docs} -> {[err | errs], docs}
        end)

      claims_with_names = Enum.reverse(claims_with_names)
      claims = Enum.map(claims_with_names, &elem(&1, 0))
      filenames = Enum.map(claims_with_names, &elem(&1, 1))

      case claims do
        [] ->
          message =
            case Enum.reverse(file_errors) do
              [] -> "Please upload at least one .json claim file."
              errors -> "No valid claim files found. " <> Enum.join(errors, " | ")
            end

          {:noreply,
           socket
           |> assign(:batch_status, :error)
           |> assign(:batch_error, message)}

        _ ->
          with :ok <- maybe_compile_batch_rules(execution_rules_text),
               {:ok, outcome} <-
                 run_batch_execution(socket, claims, filenames, file_errors, execution_rules_text) do
            {:noreply, outcome}
          else
            {:error, err} ->
              {:noreply,
               socket
               |> assign(:batch_status, :error)
               |> assign(:batch_error, err)}
          end
      end
    end
  end

  defp maybe_compile_batch_rules(rules_text) do
    case call_batch_compile(rules_text) do
      {:ok, %{"success" => true}} ->
        :ok

      {:ok, %{"success" => false, "failures" => failures}}
      when is_list(failures) and length(failures) > 0 ->
        first = List.first(failures)
        {:error, "Rule compile check failed for rule '#{first["ruleName"]}': #{first["error"]}"}

      {:ok, %{"success" => false, "error" => err}} ->
        {:error, "Rule compile check failed: #{err}"}

      {:error, err} ->
        {:error, "Rule compile check failed: #{err}"}

      _ ->
        {:error, "Rule compile check failed: unexpected response"}
    end
  end

  defp run_batch_execution(socket, claims, filenames, file_errors, rules_text) do
    batch_id = Ecto.UUID.generate()

    {:ok, batch} =
      Claims.create_batch(%{
        batch_id: batch_id,
        source: "ui_upload",
        file_count: length(claims),
        status: "processing",
        started_at: DateTime.utc_now()
      })

    socket = assign(socket, :batch_status, :processing)

    case call_batch_evaluate(rules_text, claims) do
      {:ok, %{"batchResults" => results}} ->
        enriched_results =
          results
          |> Enum.zip(filenames)
          |> Enum.map(fn {result, filename} ->
            claim_id = Ecto.UUID.generate()
            report = result["report"]
            risk = report["overallRisk"] || "LowRisk"

            status =
              if risk in ["CriticalRisk", "HighRisk"], do: "fraudulent", else: "translated"

            Claims.create_edi_file(%{
              filename: claim_id,
              file_path: "batch/#{batch_id}/#{claim_id}",
              json_output: report,
              status: status,
              batch_id: batch.id,
              processed_at: DateTime.utc_now()
            })

            result
            |> Map.put("claimId", claim_id)
            |> Map.put("fileName", filename)
          end)

        Claims.update_batch(batch, %{
          status: "completed",
          completed_at: DateTime.utc_now()
        })

        sorted_results = Enum.sort_by(enriched_results, &risk_sort_key/1)

        {:ok,
         socket
         |> assign(:batch_status, :done)
         |> assign(:batch_results, sorted_results)
         |> assign(:batch_summary, build_batch_summary(sorted_results))
         |> assign(:batch_error, file_warnings(file_errors))}

      {:error, err} ->
        Claims.update_batch(batch, %{status: "failed"})
        {:error, err}
    end
  end

  defp file_warnings([]), do: nil

  defp file_warnings(errors),
    do: "Processed valid files only. Skipped: " <> Enum.join(Enum.reverse(errors), " | ")

  defp refresh_catalog_rules(socket) do
    assign(socket, :catalog_rules, safe_list_catalogue_entries())
  end

  defp safe_list_catalogue_entries do
    Claims.list_catalogue_entries()
  rescue
    _ -> []
  end

  # Evaluation uses active BA rules from business_rules table (the DSL execution store)
  defp active_catalog_rules_text(_catalogue_entries) do
    Claims.list_active_business_rules()
    |> Enum.map(&String.trim(&1.rule_text || ""))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      entries -> Enum.join(entries, "\n\n")
    end
  end

  defp batch_execution_rules(socket) do
    case active_catalog_rules_text(socket.assigns.catalog_rules) do
      nil ->
        {"", nil, "No active BA rules available for claim processing."}

      catalog_text ->
        {parsed_rules, parse_error} = parse_batch_rules(catalog_text)
        {catalog_text, parsed_rules, parse_error}
    end
  end

  defp decode_claim_file(path, client_name) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, claim} -> {:ok, {claim, client_name}}
          {:error, _} -> {:error, "#{client_name}: invalid JSON"}
        end

      {:error, _reason} ->
        {:error, "#{client_name}: could not read file"}
    end
  end

  defp parse_batch_rules(text) do
    case parse_rule(text) do
      {:ok, %{"rule" => rules}} when is_list(rules) and length(rules) > 0 -> {rules, nil}
      {:ok, %{"success" => false, "error" => err}} -> {nil, err}
      {:ok, %{"error" => err}} -> {nil, err}
      {:ok, _} -> {nil, "Could not validate rules"}
      {:error, error} -> {nil, normalize_error(error)}
    end
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

  defp batch_rule_results(report, show_matched_only) do
    results = Map.get(report || %{}, "results", [])

    if show_matched_only do
      Enum.filter(results, &(&1["resultMatched"] == true))
    else
      results
    end
  end

  defp call_batch_evaluate(rules_text, claims) do
    body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, claims))

    case HTTPoison.post(
           "http://localhost:8080/api/batch-evaluate",
           body,
           [{"Content-Type", "application/json"}],
           timeout: 120_000,
           recv_timeout: 120_000
         ) do
      {:ok, %{status_code: 200, body: resp_body}} -> Jason.decode(resp_body)
      {:ok, %{body: resp_body}} -> {:error, resp_body}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp call_batch_compile(rules_text) do
    body = Jason.encode!(%{rulesText: normalize_dsl_text(rules_text)})

    case HTTPoison.post(
           "http://localhost:8080/api/compile-rules",
           body,
           [{"Content-Type", "application/json"}],
           timeout: 120_000,
           recv_timeout: 120_000
         ) do
      {:ok, %{status_code: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %{body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"error" => err}} -> {:error, err}
          _ -> {:error, resp_body}
        end

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp filtered_batch_results(results, nil), do: results

  defp filtered_batch_results(results, "clean") do
    Enum.filter(results, fn r -> r["report"]["matchedRules"] == 0 end)
  end

  defp filtered_batch_results(results, "flagged") do
    Enum.filter(results, fn r -> r["report"]["matchedRules"] > 0 end)
  end

  defp filtered_batch_results(results, risk_level) do
    Enum.filter(results, fn r -> r["report"]["overallRisk"] == risk_level end)
  end

  defp risk_sort_key(result) do
    case result["report"]["overallRisk"] do
      "CriticalRisk" -> 0
      "HighRisk" -> 1
      "MediumRisk" -> 2
      _ -> 3
    end
  end

  defp build_batch_summary(results) do
    total = length(results)
    matched = Enum.count(results, fn r -> r["report"]["matchedRules"] > 0 end)
    critical = Enum.count(results, fn r -> r["report"]["overallRisk"] == "CriticalRisk" end)
    high = Enum.count(results, fn r -> r["report"]["overallRisk"] == "HighRisk" end)
    %{total: total, matched: matched, critical: critical, high: high, clean: total - matched}
  end

  defp parse_rule(text) do
    normalized_text = normalize_dsl_text(text)

    case HTTPoison.post(
           "http://localhost:8080/api/parse-rule",
           Jason.encode!(%{ruleText: normalized_text}),
           [{"Content-Type", "application/json"}]
         ) do
      {:ok, %{status_code: 200, body: body}} ->
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

  defp get_default_rule do
    """
    -- Example business rule
    RULE high_claim_amount
    DESCRIPTION "Flag claims with unusually high amounts"
    WHEN 2300.CLM.02 > 50000
    THEN FLAG_FRAUD "Claim amount exceeds $50,000 threshold"
    END
    """
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

      case HTTPoison.post(
             "http://localhost:8080/api/check-redundancy",
             body,
             [{"Content-Type", "application/json"}],
             timeout: 10_000,
             recv_timeout: 10_000
           ) do
        {:ok, %{status_code: 200, body: resp_body}} ->
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
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&format_dsl_line/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp action_badge_text(nil), do: nil

  defp action_badge_text(%{"tag" => tag, "contents" => contents}) do
    case tag do
      "FlagFraud'" -> "FLAG FRAUD"
      "RejectClaim'" -> "REJECT"
      "RequireReview'" -> "REVIEW"
      "AssignRiskScore'" when is_integer(contents) -> "RISK: #{contents}"
      "ApproveClaim'" -> "APPROVE"
      "CompositeAction'" -> "COMPOSITE"
      _ -> String.upcase(tag)
    end
  end

  defp action_badge_text(%{"tag" => tag}), do: String.upcase(String.replace(tag, "'", ""))
  defp action_badge_text(_), do: nil

  defp action_severity_classes(nil), do: "border-gray-300 bg-gray-50"

  defp action_severity_classes(%{"tag" => tag, "contents" => contents}) do
    case tag do
      "FlagFraud'" -> "border-red-400 bg-red-50"
      "RejectClaim'" -> "border-red-400 bg-red-50"
      "RequireReview'" -> "border-yellow-400 bg-yellow-50"
      "AssignRiskScore'" when is_integer(contents) and contents >= 70 -> "border-orange-400 bg-orange-50"
      "AssignRiskScore'" -> "border-yellow-400 bg-yellow-50"
      "ApproveClaim'" -> "border-green-400 bg-green-50"
      _ -> "border-gray-300 bg-gray-50"
    end
  end

  defp action_severity_classes(%{"tag" => tag}) do
    case tag do
      "FlagFraud'" -> "border-red-400 bg-red-50"
      "RejectClaim'" -> "border-red-400 bg-red-50"
      "RequireReview'" -> "border-yellow-400 bg-yellow-50"
      "ApproveClaim'" -> "border-green-400 bg-green-50"
      _ -> "border-gray-300 bg-gray-50"
    end
  end

  defp action_severity_classes(_), do: "border-gray-300 bg-gray-50"

  defp action_badge_color(nil), do: "bg-gray-200 text-gray-700"

  defp action_badge_color(%{"tag" => tag}) do
    case tag do
      "FlagFraud'" -> "bg-red-200 text-red-800"
      "RejectClaim'" -> "bg-red-200 text-red-800"
      "RequireReview'" -> "bg-yellow-200 text-yellow-900"
      "AssignRiskScore'" -> "bg-orange-200 text-orange-800"
      "ApproveClaim'" -> "bg-green-200 text-green-800"
      _ -> "bg-gray-200 text-gray-700"
    end
  end

  defp action_badge_color(_), do: "bg-gray-200 text-gray-700"

  defp match_ratio_bar_color(matched, total) when total > 0 do
    ratio = matched * 100.0 / total

    cond do
      ratio > 60 -> "bg-red-500"
      ratio > 30 -> "bg-yellow-500"
      true -> "bg-green-500"
    end
  end

  defp match_ratio_bar_color(_, _), do: "bg-gray-400"

  defp match_ratio_percent(matched, total) when total > 0,
    do: Float.round(matched * 100.0 / total, 1)

  defp match_ratio_percent(_, _), do: 0.0

  defp risk_score_value("CriticalRisk"), do: 90
  defp risk_score_value("HighRisk"), do: 65
  defp risk_score_value("MediumRisk"), do: 35
  defp risk_score_value("LowRisk"), do: 5
  defp risk_score_value(_), do: 0

  defp risk_bar_color("CriticalRisk"), do: "bg-red-500"
  defp risk_bar_color("HighRisk"), do: "bg-orange-500"
  defp risk_bar_color("MediumRisk"), do: "bg-yellow-500"
  defp risk_bar_color("LowRisk"), do: "bg-blue-500"
  defp risk_bar_color(_), do: "bg-gray-400"

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
