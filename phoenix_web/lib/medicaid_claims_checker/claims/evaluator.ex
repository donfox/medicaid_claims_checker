defmodule MedicaidClaimsChecker.Claims.Evaluator do
  @moduledoc """
  Headless claim evaluation engine. Runs NPPES pre-validation and then sends
  claims to the Haskell rule engine for batch evaluation, storing results
  back into the database.

  Extracted from RuleLive.Index so it can be triggered both from the UI
  and automatically when scheduled X12 batches arrive.
  """

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder

  require Logger

  defp rule_engine_url do
    Application.get_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
  end

  defp engine_secret do
    Application.get_env(:medicaid_claims_checker, :rule_engine_secret, "")
  end

  defp engine_headers do
    [{"Content-Type", "application/json"}, {"Authorization", "Bearer #{engine_secret()}"}]
  end

  @doc """
  Evaluates all edi_files in a batch that are in "translated" status.

  Steps:
    1. Gather active BA rules
    2. NPPES pre-validation (hard-reject invalid provider NPIs)
    3. Send passing claims to Haskell rule engine
    4. Store results back on each edi_file record
    5. Mark batch completed (or failed)

  Returns {:ok, batch} | {:error, reason}.
  """
  @topic "batch:events"

  def topic, do: @topic

  def evaluate_batch(batch) do
    edi_files =
      Claims.list_files_for_batch(batch.id)
      |> Enum.filter(&(&1.status == "translated"))

    if edi_files == [] do
      result =
        Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})

      broadcast_completed(batch)
      result
    else
      Claims.update_batch(batch, %{status: "processing"})
      do_evaluate(batch, edi_files)
    end
  end

  defp do_evaluate(batch, edi_files) do
    case gather_rules_text() do
      nil ->
        Logger.warning(
          "No active BA rules — marking batch #{batch.batch_id} completed without evaluation"
        )

        Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
        broadcast_completed(batch)

      rules_text ->
        evaluate_with_engine(batch, edi_files, rules_text)
    end
  end

  defp gather_rules_text do
    Claims.list_active_business_rules()
    |> Enum.map(&String.trim(&1.rule_text || ""))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      entries -> Enum.join(entries, "\n\n")
    end
  end

  defp evaluate_with_engine(batch, edi_files, rules_text) do
    claims = Enum.map(edi_files, & &1.json_output)
    nppes_outcomes = Enum.map(edi_files, &Claims.validate_claim_providers(&1.json_output))

    case call_batch_evaluate(rules_text, claims) do
      {:ok, %{"batchResults" => results}} ->
        if length(results) != length(edi_files) do
          reason =
            "Result count mismatch: expected #{length(edi_files)}, got #{length(results)}"

          Logger.error("Batch evaluation failed for #{batch.batch_id}: #{reason}")
          Claims.update_batch(batch, %{status: "failed"})
          broadcast_failed(batch, reason)
        else
          [results, edi_files, nppes_outcomes]
          |> Enum.zip()
          |> Enum.each(fn {result, edi_file, nppes_outcome} ->
            report =
              result
              |> Map.get("report", %{})
              |> merge_nppes_finding(nppes_outcome)

            risk = report["overallRisk"] || "LowRisk"
            status = if risk in ["CriticalRisk", "HighRisk"], do: "fraudulent", else: "evaluated"

            Claims.update_edi_file_evaluation(edi_file, %{
              json_output: report,
              status: status,
              processed_at: DateTime.utc_now()
            })
          end)

          Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
          broadcast_completed(batch)
        end

      {:error, reason} ->
        Logger.error("Batch evaluation failed for #{batch.batch_id}: #{inspect(reason)}")
        Claims.update_batch(batch, %{status: "failed"})
        broadcast_failed(batch, reason)
    end
  end

  @batch_chunk_size 200

  defp call_batch_evaluate(rules_text, claims) do
    claims
    |> Enum.chunk_every(@batch_chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, chunk))

      case HTTPoison.post(
             "#{rule_engine_url()}/api/batch-evaluate",
             body,
             engine_headers(),
             timeout: 120_000,
             recv_timeout: 120_000
           ) do
        {:ok, %{status_code: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"batchResults" => results}} -> {:cont, {:ok, acc ++ results}}
            {:ok, _} -> {:halt, {:error, "Unexpected response format from evaluator"}}
            {:error, _} -> {:halt, {:error, "Invalid JSON from evaluator"}}
          end

        {:ok, %{body: resp_body}} ->
          {:halt, {:error, resp_body}}

        {:error, err} ->
          {:halt, {:error, inspect(err)}}
      end
    end)
    |> case do
      {:ok, all_results} -> {:ok, %{"batchResults" => all_results}}
      {:error, _} = error -> error
    end
  end

  defp broadcast_completed(batch) do
    summary = Claims.batch_summary(batch.id)
    edi_files = Claims.list_files_for_batch(batch.id)

    files =
      Enum.map(edi_files, fn f ->
        report = f.json_output || %{}

        matched_results =
          (report["results"] || [])
          |> Enum.filter(& &1["resultMatched"])
          |> Enum.map(fn r ->
            %{rule: r["resultRuleName"], detail: r["resultDetails"]}
          end)

        %{
          filename: f.filename,
          status: f.status,
          risk: report["overallRisk"] || "LowRisk",
          matched_rules: report["matchedRules"] || 0,
          matched_results: matched_results
        }
      end)

    Phoenix.PubSub.broadcast(
      MedicaidClaimsChecker.PubSub,
      @topic,
      {:batch_completed, %{batch_id: batch.batch_id, summary: summary, files: files}}
    )
  end

  defp broadcast_failed(batch, reason) do
    Phoenix.PubSub.broadcast(
      MedicaidClaimsChecker.PubSub,
      @topic,
      {:batch_failed, %{batch_id: batch.batch_id, reason: inspect(reason)}}
    )
  end

  defp merge_nppes_finding(report, :ok), do: report

  defp merge_nppes_finding(report, {:reject, reason}) when is_map(report) do
    existing_results = report["results"] || []

    already_present? =
      Enum.any?(existing_results, fn result ->
        result["resultRuleName"] == "NPPESProviderLookup"
      end)

    results =
      if already_present? do
        existing_results
      else
        existing_results ++
          [
            %{
              "resultRuleName" => "NPPESProviderLookup",
              "resultMatched" => true,
              "resultAction" => %{"tag" => "RejectClaim'", "contents" => reason},
              "resultDetails" => reason
            }
          ]
      end

    matched_rules = Enum.count(results, &(&1["resultMatched"] == true))
    total_rules = max(report["totalRules"] || 0, length(results))

    report
    |> Map.put("results", results)
    |> Map.put("matchedRules", matched_rules)
    |> Map.put("totalRules", total_rules)
    |> Map.put("overallRisk", "CriticalRisk")
  end
end
