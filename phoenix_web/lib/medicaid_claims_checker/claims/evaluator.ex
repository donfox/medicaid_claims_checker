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
  alias MedicaidClaimsChecker.Claims.PayloadBuilder

  require Logger

  # Batches are sent to the engine in chunks of @batch_chunk_size (200), so a
  # 15,000-claim batch is 75 requests. The engine accepts 1000 requests a
  # minute from one IP address, and all of this app's requests share that
  # address: the cap leaves room for ten such batches at once plus Rules page
  # calls, and the batch_evaluation queue runs at most ten (config.exs). A 429
  # is retried after a wait (post_chunk/2). Revisit it if the chunk size, the
  # queue limit or the engine's rate limit (haskell_engine/app/Middleware.hs)
  # changes.
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
    1. Gather the text of every active rule (Default and BA Rules)
    2. Check each claim's provider NPIs against NPPES
    3. Send every claim to the Haskell rule engine, in chunks of 200; a
       claim that failed the NPPES check gets that rejection added to its
       report afterwards
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
          "No active rules — marking batch #{batch.batch_id} completed without evaluation"
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
            Claims.update_edi_file_evaluation(
              edi_file,
              evaluation_attrs(result, nppes_outcome)
            )
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

  # Every chunk carries the full rules text on purpose. The engine keeps no
  # state, so it can never run stale rules after an edit; the text is ~1% of a
  # chunk and parses in microseconds. The engine's rule cache and
  # /api/compile-rules were removed for this reason in 41dcbdb (2026-10-15).

  # Connecting succeeds or is refused at once on the same machine; 10 s covers
  # an engine on another host without waiting long for one that is gone.
  @connect_timeout_ms 10_000

  # Not the engine's 30 s: that limit is per claim. The engine checks one claim
  # per CPU core at a time, shared by every Phoenix job, so a chunk of 200 slow
  # claims could take many times 30 s. Real claims take milliseconds, so 120 s
  # is a safety net. A stalled engine costs one wait per batch, not per chunk:
  # the first failed request stops the batch, which is marked failed (its
  # claims show as not evaluated, and the duplicate check lets the same file be
  # submitted again). Only the batch_evaluation queue waits; nothing else does.
  @receive_timeout_ms 120_000

  # The engine answers 429 when this app's address has made too many requests
  # in the last 60 s; every Phoenix request shares that one address. A 429 is
  # a reason to slow down, not a failed batch: wait the Retry-After time (at
  # most 60 s) and send the same chunk again, up to @rate_limit_retries times.
  @rate_limit_retries 3

  defp post_chunk(body, retries_left \\ @rate_limit_retries) do
    case EngineClient.post("/api/batch-evaluate", body,
           connect_timeout: @connect_timeout_ms,
           receive_timeout: @receive_timeout_ms
         ) do
      {:ok, %{status: 429} = resp} when retries_left > 0 ->
        wait_ms = rate_limit_wait_ms(resp)

        Logger.warning(
          "Rule engine rate limit reached; sending the chunk again in #{div(wait_ms, 1000)} s " <>
            "(#{retries_left} #{if retries_left == 1, do: "retry", else: "retries"} left)"
        )

        Process.sleep(wait_ms)
        post_chunk(body, retries_left - 1)

      other ->
        other
    end
  end

  # Tests set :engine_rate_limit_wait_ms so they do not wait a minute.
  defp rate_limit_wait_ms(resp) do
    case Application.get_env(:medicaid_claims_checker, :engine_rate_limit_wait_ms) do
      ms when is_integer(ms) -> ms
      nil -> retry_after_ms(Req.Response.get_header(resp, "retry-after"))
    end
  end

  @doc false
  # Milliseconds to wait from a Retry-After header's values: whole seconds,
  # at most 60; 60 when missing or not a number (the engine sends 60).
  def retry_after_ms(values) do
    seconds =
      with [value | _] <- values,
           {n, ""} when n >= 0 <- Integer.parse(String.trim(value)) do
        min(n, 60)
      else
        _ -> 60
      end

    seconds * 1000
  end

  defp call_batch_evaluate(rules_text, claims) do
    claims
    |> Enum.chunk_every(@batch_chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, chunk))

      case post_chunk(body) do
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

  # The engine returns a report for each claim, or an error when it could not
  # check the claim (e.g. {"error": "evaluation timed out after 30 s",
  # "reason": "timeout"}). A claim with an error is stored as "not_assessed",
  # never as evaluated: its rules were not checked, so it must not look clean.
  # A provider (NPPES) rejection is still a real finding and is kept.
  # The report is a recommendation for an analyst; risk level never changes
  # the file's status.
  defp evaluation_attrs(%{"report" => report}, nppes_outcome) when is_map(report) do
    report =
      report
      |> merge_nppes_finding(nppes_outcome)
      |> put_weighted_score()

    %{evaluation_report: report, status: "evaluated", processed_at: DateTime.utc_now()}
  end

  defp evaluation_attrs(result, nppes_outcome) do
    message =
      case result do
        %{"error" => error} when is_binary(error) and error != "" -> error
        _ -> "the rule engine returned no report for this claim"
      end

    reason =
      case result do
        %{"reason" => r} when is_binary(r) and r != "" -> r
        _ -> "error"
      end

    report =
      case nppes_outcome do
        {:reject, _} ->
          %{}
          |> merge_nppes_finding(nppes_outcome)
          |> put_weighted_score()
          |> Map.put("summary", "Rules not checked: #{message}. Provider check failed.")

        _ ->
          nil
      end

    %{
      evaluation_report: report,
      status: "not_assessed",
      error_message: message,
      error_details: %{"reason" => reason},
      processed_at: DateTime.utc_now()
    }
  end

  defp put_weighted_score(report) do
    Map.put(report, "weightedScore", compute_weighted_score(report["results"] || []))
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
          risk:
            report["overallRisk"] ||
              if(f.status == "not_assessed", do: "Not assessed", else: "LowRisk"),
          error: f.error_message,
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
      {:batch_failed,
       %{
         batch_id: batch.batch_id,
         reason: if(is_binary(reason), do: reason, else: inspect(reason))
       }}
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
    |> Map.put(
      "summary",
      report_summary(total_rules, matched_rules, report["undecidedRules"] || 0, "CriticalRisk")
    )
  end

  # The engine writes the summary before the NPPES finding is added, so it is
  # rewritten from the merged counts, in the engine's wording
  # (generateSummary in haskell_engine/src/Claims/Evaluator.hs).
  defp report_summary(total, matched, undecided, risk) do
    not_checked = if undecided > 0, do: ", #{undecided} not checked (missing data). ", else: ". "
    "Evaluated #{total} rules, #{matched} matched#{not_checked}Overall risk: #{risk}"
  end
end
