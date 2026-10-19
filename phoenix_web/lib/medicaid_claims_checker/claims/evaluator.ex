defmodule MedicaidClaimsChecker.Claims.Evaluator do
  @moduledoc """
  Headless claim evaluation engine. Runs NPPES pre-validation and then sends
  claims to the Haskell rule engine for batch evaluation, storing results
  back into the database.

  Extracted from RuleLive.Index so it can be triggered both from the UI
  and automatically when scheduled X12 batches arrive.
  """

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.EngineClient
  alias MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder

  require Logger

  # Batches are sent to the engine in chunks of @batch_chunk_size (200), and
  # the engine accepts at most 100 requests a minute on one connection, so a
  # batch over about 20,000 claims would be rejected partway through. The cap
  # leaves room for other requests on the same connection. Revisit it if the
  # chunk size or the engine's rate limit (haskell_engine/app/Main.hs) changes.
  @max_batch_claims 15_000

  @doc "Largest number of claims a single batch may send to the engine."
  def max_batch_claims, do: @max_batch_claims

  @doc "Message shown when a batch has more claims than `max_batch_claims/0`."
  def batch_too_large_message(claim_count) do
    "This batch has #{claim_count} claims; the limit is #{@max_batch_claims}. " <>
      "Split the files into smaller batches and try again."
  end

  @doc """
  Evaluates all edi_files in a batch that are in "translated" status.

  Steps:
    1. Gather active BA rules
    2. NPPES pre-validation (hard-reject invalid provider NPIs)
    3. Send passing claims to Haskell rule engine
    4. Store each report in `evaluation_report` (the claim in `json_output`
       is left untouched) and mark the file "evaluated"
    5. Mark batch completed (or failed)

  Returns {:ok, batch} | {:error, reason}.
  """
  @topic "batch:events"

  def topic, do: @topic

  def evaluate_batch(batch) do
    edi_files =
      Claims.list_files_for_batch(batch.id)
      |> Enum.filter(&(&1.status == "translated"))

    cond do
      edi_files == [] ->
        result =
          Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})

        broadcast_completed(batch)
        result

      length(edi_files) > @max_batch_claims ->
        reason = batch_too_large_message(length(edi_files))
        Logger.error("Batch evaluation refused for #{batch.batch_id}: #{reason}")
        result = Claims.update_batch(batch, %{status: "failed"})
        broadcast_failed(batch, reason)
        result

      true ->
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
              |> then(fn r ->
                Map.put(r, "weightedScore", compute_weighted_score(r["results"] || []))
              end)

            # The report is a recommendation for an analyst; risk level never
            # changes the file's status.
            Claims.update_edi_file_evaluation(edi_file, %{
              evaluation_report: report,
              status: "evaluated",
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

  # 200 claims per HTTP request keeps payloads under ~5 MB and engine memory stable.
  @batch_chunk_size 200

  defp call_batch_evaluate(rules_text, claims) do
    claims
    |> Enum.chunk_every(@batch_chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, chunk))

      case EngineClient.post("/api/batch-evaluate", body,
             connect_timeout: 120_000,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: resp_body}} ->
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
        report = f.evaluation_report || %{}

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
          weighted_score: report["weightedScore"] || 0,
          matched_results: matched_results,
          not_checked_count: report["undecidedRules"] || 0
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

  defp compute_weighted_score(results) do
    results
    |> Enum.filter(& &1["resultMatched"])
    |> Enum.map(fn r -> action_weight(r["resultAction"] || %{}) end)
    |> Enum.sum()
  end

  # Weights correspond to severity: reject (3) > fraud flag (2) > review (1).
  # The score is advisory; flagging for review is driven by overallRisk.
  defp action_weight(%{"tag" => "RejectClaim'"}), do: 3
  defp action_weight(%{"tag" => "FlagFraud'"}), do: 2
  defp action_weight(%{"tag" => "RequireReview'"}), do: 1

  defp action_weight(%{"tag" => "CompositeAction'", "contents" => actions})
       when is_list(actions),
       do: Enum.sum(Enum.map(actions, &action_weight/1))

  defp action_weight(_), do: 0

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
    |> Map.put("summary", report_summary(total_rules, matched_rules, report["undecidedRules"] || 0, "CriticalRisk"))
  end

  # The engine writes the summary before the NPPES finding is added, so it is
  # rewritten from the merged counts, in the engine's wording
  # (generateSummary in haskell_engine/src/Claims/RuleEngine.hs).
  defp report_summary(total, matched, undecided, risk) do
    not_checked = if undecided > 0, do: ", #{undecided} not checked (missing data). ", else: ". "
    "Evaluated #{total} rules, #{matched} matched#{not_checked}Overall risk: #{risk}"
  end
end
