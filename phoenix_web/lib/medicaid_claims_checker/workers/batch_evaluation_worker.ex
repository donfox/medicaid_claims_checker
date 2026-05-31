defmodule MedicaidClaimsChecker.Workers.BatchEvaluationWorker do
  @moduledoc """
  Oban worker that runs claim evaluation for a single batch.

  Enqueued automatically after `Claims.ingest_batch/1` succeeds.
  Deduplication (`unique: [period: 60]`) prevents double-evaluation if the
  same batch_id is enqueued more than once within a 60-second window.
  """

  use Oban.Worker,
    queue: :batch_evaluation,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Evaluator

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    case Claims.get_batch(batch_id) do
      nil ->
        Logger.warning("BatchEvaluationWorker: batch #{batch_id} not found, skipping")
        :ok

      batch ->
        Logger.info("BatchEvaluationWorker: evaluating batch #{batch.batch_id}")
        Evaluator.evaluate_batch(batch)
    end
  end
end
