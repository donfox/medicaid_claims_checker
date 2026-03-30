defmodule MedicaidClaimsChecker.Claims.Evaluator do
  @moduledoc """
  Headless claim evaluation engine. Runs NPPES pre-validation and then sends
  claims to the Haskell rule engine for batch evaluation, storing results
  back into the database.

  Extracted from RuleLive.Index so it can be triggered both from the UI
  and automatically when X12Translator batches arrive.
  """

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder

  require Logger

  defp rule_engine_url do
    Application.get_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
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
      result = Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
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
        Logger.warning("No active BA rules — marking batch #{batch.batch_id} completed without evaluation")
        Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
        broadcast_completed(batch)

      rules_text ->
        {passing, rejections} = nppes_pre_evaluate(edi_files)

        Enum.each(rejections, fn {edi_file, reason} ->
          report = nppes_rejection_report(reason)

          Claims.update_edi_file_evaluation(edi_file, %{
            json_output: report,
            status: "fraudulent",
            processed_at: DateTime.utc_now()
          })
        end)

        if passing == [] do
          Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
          broadcast_completed(batch)
        else
          evaluate_with_engine(batch, passing, rules_text)
        end
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

  defp nppes_pre_evaluate(edi_files) do
    Enum.reduce(edi_files, {[], []}, fn edi_file, {pass, reject} ->
      case Claims.validate_claim_providers(edi_file.json_output) do
        :ok -> {[edi_file | pass], reject}
        {:reject, reason} -> {pass, [{edi_file, reason} | reject]}
      end
    end)
    |> then(fn {pass, reject} -> {Enum.reverse(pass), Enum.reverse(reject)} end)
  end

  defp evaluate_with_engine(batch, edi_files, rules_text) do
    claims = Enum.map(edi_files, & &1.json_output)

    case call_batch_evaluate(rules_text, claims) do
      {:ok, %{"batchResults" => results}} ->
        results
        |> Enum.zip(edi_files)
        |> Enum.each(fn {result, edi_file} ->
          report = result["report"]
          risk = report["overallRisk"] || "LowRisk"
          status = if risk in ["CriticalRisk", "HighRisk"], do: "fraudulent", else: "translated"

          Claims.update_edi_file_evaluation(edi_file, %{
            json_output: report,
            status: status,
            processed_at: DateTime.utc_now()
          })
        end)

        Claims.update_batch(batch, %{status: "completed", completed_at: DateTime.utc_now()})
        broadcast_completed(batch)

      {:error, reason} ->
        Logger.error("Batch evaluation failed for #{batch.batch_id}: #{inspect(reason)}")
        Claims.update_batch(batch, %{status: "failed"})
        broadcast_failed(batch, reason)
    end
  end

  defp call_batch_evaluate(rules_text, claims) do
    body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, claims))

    case HTTPoison.post(
           "#{rule_engine_url()}/api/batch-evaluate",
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

  defp nppes_rejection_report(reason) do
    %{
      "overallRisk" => "CriticalRisk",
      "matchedRules" => 1,
      "totalRules" => 1,
      "results" => [
        %{
          "resultRuleName" => "NPPESProviderLookup",
          "resultMatched" => true,
          "resultAction" => %{"tag" => "RejectClaim'", "contents" => reason},
          "resultDetails" => reason
        }
      ]
    }
  end
end
