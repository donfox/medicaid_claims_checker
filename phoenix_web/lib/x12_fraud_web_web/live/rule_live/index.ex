defmodule X12FraudWebWeb.RuleLive.Index do
  use X12FraudWebWeb, :live_view
  import X12FraudWebWeb.Components.RuleComponents
  alias X12FraudWeb.Claims
  alias X12FraudWebWeb.RuleLive.PayloadBuilder

  @impl true
  def mount(_params, _session, socket) do
    default_rule = get_default_rule()
    catalog_rules = safe_list_business_rules()

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
     |> assign(:batch_show_matched_only, false)
     |> assign(:catalog_rules, catalog_rules)
     |> assign(:catalog_rule_name, "")
     |> assign(:catalog_rule_text, "")
     |> assign(:catalog_parse_error, nil)
     |> assign(:catalog_parsed_rule, nil)
     |> assign(:selected_catalog_rule_id, nil)
     |> assign(:catalog_error, nil)
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
    selected_rule_id = socket.assigns.selected_catalog_rule_id
    normalized_rule_text = normalize_dsl_text(Map.get(params, "text", ""))
    name = String.trim(Map.get(params, "name", ""))

    {_parsed, parse_error} = parse_single_rule_text(normalized_rule_text)

    if parse_error != nil do
      {:noreply, assign(socket, :catalog_error, "Could not save rule: #{parse_error}")}
    else
      if selected_rule_id do
        with %{} = rule <- Claims.get_business_rule(selected_rule_id),
             {:ok, _updated} <-
               Claims.update_business_rule(rule, %{
                 name: name,
                 rule_text: String.trim(normalized_rule_text),
                 active: rule.active
               }) do
          {:noreply,
           socket
           |> refresh_catalog_rules()
           |> assign(:catalog_rule_name, "")
           |> assign(:catalog_rule_text, "")
           |> assign(:catalog_parsed_rule, nil)
           |> assign(:catalog_parse_error, nil)
           |> assign(:selected_catalog_rule_id, nil)
           |> assign(:catalog_error, nil)
           |> put_flash(:info, "Business rule updated.")}
        else
          {:error, changeset} ->
            message =
              changeset.errors
              |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
              |> Enum.join(", ")

            {:noreply, assign(socket, :catalog_error, "Could not save rule: #{message}")}

          _ ->
            {:noreply, assign(socket, :catalog_error, "Could not save rule.")}
        end
      else
        attrs = %{
          name: name,
          rule_text: String.trim(normalized_rule_text),
          active: true
        }

        case Claims.create_business_rule(attrs) do
          {:ok, _rule} ->
            {:noreply,
             socket
             |> refresh_catalog_rules()
             |> assign(:catalog_rule_name, "")
             |> assign(:catalog_rule_text, "")
             |> assign(:catalog_parsed_rule, nil)
             |> assign(:catalog_parse_error, nil)
             |> assign(:catalog_error, nil)
             |> put_flash(:info, "Business rule saved to catalog.")}

          {:error, changeset} ->
            message =
              changeset.errors
              |> Enum.map(fn {field, {error, _}} -> "#{field} #{error}" end)
              |> Enum.join(", ")

            {:noreply, assign(socket, :catalog_error, "Could not save rule: #{message}")}
        end
      end
    end
  end

  @impl true
  def handle_event("toggle_catalog_rule_active", %{"id" => id}, socket) do
    with {rule_id, ""} <- Integer.parse(id),
         %{} = rule <- Claims.get_business_rule(rule_id),
         {:ok, _updated} <- Claims.toggle_business_rule_active(rule) do
      {:noreply, socket |> refresh_catalog_rules() |> assign(:catalog_error, nil)}
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not update rule status.")}
    end
  end

  @impl true
  def handle_event("delete_catalog_rule", %{"id" => id}, socket) do
    with {rule_id, ""} <- Integer.parse(id),
         %{} = rule <- Claims.get_business_rule(rule_id),
         {:ok, _deleted} <- Claims.delete_business_rule(rule) do
      {:noreply,
       socket
       |> refresh_catalog_rules()
       |> assign(:catalog_error, nil)
       |> put_flash(:info, "Business rule removed from catalog.")}
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not remove rule.")}
    end
  end

  @impl true
  def handle_event("select_catalog_rule", %{"id" => id}, socket) do
    with {rule_id, ""} <- Integer.parse(id),
         %{} = rule <- Claims.get_business_rule(rule_id) do
      rule_text = rule.rule_text || ""
      {parsed_rule, parse_error} = parse_single_rule_text(rule_text)

      {:noreply,
       socket
       |> assign(:catalog_rule_name, rule.name || "")
       |> assign(:catalog_rule_text, rule_text)
       |> assign(:catalog_parsed_rule, parsed_rule)
       |> assign(:catalog_parse_error, parse_error)
       |> assign(:selected_catalog_rule_id, rule.id)
       |> assign(:catalog_error, nil)}
    else
      _ -> {:noreply, assign(socket, :catalog_error, "Could not load rule from catalog.")}
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
     |> assign(:catalog_error, nil)}
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

      {file_errors, claims} =
        Enum.reduce(consumed, {[], []}, fn
          {:ok, claim}, {errs, docs} -> {errs, [claim | docs]}
          {:error, err}, {errs, docs} -> {[err | errs], docs}
        end)

      claims = Enum.reverse(claims)

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
                 run_batch_execution(socket, claims, file_errors, execution_rules_text) do
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

  defp run_batch_execution(socket, claims, file_errors, rules_text) do
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
          Enum.map(results, fn result ->
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

            Map.put(result, "claimId", claim_id)
          end)

        Claims.update_batch(batch, %{
          status: "completed",
          completed_at: DateTime.utc_now()
        })

        {:ok,
         socket
         |> assign(:batch_status, :done)
         |> assign(:batch_results, enriched_results)
         |> assign(:batch_summary, build_batch_summary(enriched_results))
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
    socket
    |> assign(:catalog_rules, safe_list_business_rules())
  end

  defp safe_list_business_rules do
    Claims.list_business_rules()
  rescue
    _ -> []
  end

  defp active_catalog_rules_text(catalog_rules) do
    catalog_rules
    |> Enum.filter(& &1.active)
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
        {"", nil, "No active catalog rules available for claim processing."}

      catalog_text ->
        {parsed_rules, parse_error} = parse_batch_rules(catalog_text)
        {catalog_text, parsed_rules, parse_error}
    end
  end

  defp decode_claim_file(path, client_name) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, claim} -> {:ok, claim}
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

  defp batch_rule_overview(batch_results) do
    batch_results
    |> Enum.flat_map(fn result -> get_in(result, ["report", "results"]) || [] end)
    |> Enum.group_by(fn rule_result -> rule_result["resultRuleName"] || "Unnamed Rule" end)
    |> Enum.map(fn {rule_name, rule_results} ->
      total_claims = length(rule_results)
      matched_claims = Enum.count(rule_results, &(&1["resultMatched"] == true))

      %{
        name: rule_name,
        matched_claims: matched_claims,
        not_matched_claims: total_claims - matched_claims,
        match_rate:
          if(total_claims > 0,
            do: Float.round(matched_claims * 100.0 / total_claims, 1),
            else: 0.0
          )
      }
    end)
    |> Enum.sort_by(fn item -> {-item.matched_claims, item.name} end)
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

  defp build_batch_summary(results) do
    total = length(results)
    matched = Enum.count(results, fn r -> r["report"]["matchedRules"] > 0 end)
    critical = Enum.count(results, fn r -> r["report"]["overallRisk"] == "CriticalRisk" end)
    high = Enum.count(results, fn r -> r["report"]["overallRisk"] == "HighRisk" end)
    %{total: total, matched: matched, critical: critical, high: high, clean: total - matched}
  end

  defp parse_rule(text) do
    normalized_text = normalize_dsl_text(text)

    # Call Haskell backend to parse rule
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

  defp normalize_dsl_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("ENDRULE", "END RULE")
  end
end
