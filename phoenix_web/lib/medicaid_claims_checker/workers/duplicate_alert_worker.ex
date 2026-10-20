defmodule MedicaidClaimsChecker.Workers.DuplicateAlertWorker do
  @moduledoc """
  Oban worker that emails the admins about a batch's refused duplicates
  (see `Claims.DuplicateAlert`). Enqueued by `Claims.ingest_batch/1`; a
  mailer failure is retried.
  """

  use Oban.Worker,
    queue: :alerts,
    max_attempts: 5,
    unique: [period: 300, fields: [:args]]

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.DuplicateAlert

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
    case Claims.get_batch(batch_id) do
      nil ->
        Logger.warning("DuplicateAlertWorker: batch #{batch_id} not found, skipping")
        :ok

      batch ->
        case DuplicateAlert.deliver(batch) do
          {:ok, []} ->
            Logger.warning(
              "Duplicate alert for batch #{batch.batch_id} not sent: no active admin users"
            )

            :ok

          {:ok, recipients} ->
            Logger.info(
              "Duplicate alert for batch #{batch.batch_id} sent to #{length(recipients)} admin(s)"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
