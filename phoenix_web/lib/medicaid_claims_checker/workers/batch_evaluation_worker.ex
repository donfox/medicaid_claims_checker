defmodule MedicaidClaimsChecker.Workers.BatchEvaluationWorker do
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
