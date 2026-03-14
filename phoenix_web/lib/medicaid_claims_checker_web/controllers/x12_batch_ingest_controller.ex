defmodule MedicaidClaimsCheckerWeb.X12BatchIngestController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Claims

  def create(conn, %{"batch_id" => _, "claims" => _} = params) do
    case Claims.ingest_batch(params) do
      {:ok, %{batch: batch, edi_files: edi_files}} ->
        conn
        |> put_status(:created)
        |> render(:created, batch: batch, edi_files: edi_files)

      {:error, {:batch, changeset}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, reason: "Batch creation failed", changeset: changeset)

      {:error, {:edi_file, filename, changeset}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, reason: "Failed to ingest claim: #{filename}", changeset: changeset)

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid payload. Required: batch_id, claims[]"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid payload. Required: batch_id, claims[{filename, claim}]"})
  end

  def show(conn, %{"batch_id" => batch_id}) do
    case Claims.get_batch_by_batch_id(batch_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Batch not found"})

      batch ->
        summary = Claims.batch_summary(batch.id)
        edi_files = Claims.list_files_for_batch(batch.id)

        conn
        |> put_status(:ok)
        |> render(:show, batch: batch, summary: summary, edi_files: edi_files)
    end
  end
end
