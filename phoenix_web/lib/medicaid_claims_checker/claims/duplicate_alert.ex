defmodule MedicaidClaimsChecker.Claims.DuplicateAlert do
  @moduledoc """
  Emails the admin users when a batch refuses duplicate submissions.

  The same refusals are shown in Batch History on the Fetch Source page;
  this makes sure someone hears about them when nobody is watching, as with
  scheduled fetches. Sent by `Workers.DuplicateAlertWorker`.
  """

  import Swoosh.Email

  alias MedicaidClaimsChecker.{Accounts, Claims, Mailer}
  alias MedicaidClaimsChecker.Claims.Batch

  @doc """
  Sends the alert for `batch` to every active admin. Returns
  `{:ok, recipients}`, `{:ok, []}` when there are no admins, or
  `{:error, reason}` if the mailer fails.
  """
  def deliver(%Batch{duplicates: duplicates}) when duplicates in [nil, []], do: {:ok, []}

  def deliver(%Batch{} = batch) do
    case Accounts.list_admin_emails() do
      [] ->
        {:ok, []}

      recipients ->
        with {:ok, _} <- recipients |> email(batch) |> Mailer.deliver(), do: {:ok, recipients}
    end
  end

  @doc "The alert email for `batch`, addressed to `recipients`."
  def email(recipients, %Batch{} = batch) do
    new()
    |> to(recipients)
    |> from(
      {"MedicaidClaimsChecker",
       System.get_env("BREVO_MAIL_DEFAULT_SENDER") || "contact@example.com"}
    )
    |> subject("Duplicate submission refused: #{batch.batch_name}")
    |> text_body(body(batch))
  end

  defp body(batch) do
    count = length(batch.duplicates)

    evaluated =
      if batch.status == "failed",
        do: "none (every claim was already submitted)",
        else: "#{batch.file_count}"

    """
    #{count} duplicate submission#{if count == 1, do: " was", else: "s were"} refused and not evaluated again.

    Batch:    #{batch.batch_name}
    Source:   #{batch.source}
    Received: #{format_time(batch.inserted_at)}
    Claims evaluated from this batch: #{evaluated}

    Refused:
    #{Enum.map_join(batch.duplicates, "\n", &("  - " <> Claims.describe_duplicate(&1)))}

    The batch is listed in Batch History on the Fetch Source page:
    #{MedicaidClaimsCheckerWeb.Endpoint.url()}/
    """
  end

  defp format_time(%DateTime{} = dt),
    do:
      dt |> DateTime.shift_zone!("America/New_York") |> Calendar.strftime("%b %d, %Y %I:%M %p %Z")

  defp format_time(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> format_time()

  defp format_time(_), do: "unknown"
end
