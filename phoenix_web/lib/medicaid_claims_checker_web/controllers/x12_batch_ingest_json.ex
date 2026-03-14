defmodule MedicaidClaimsCheckerWeb.X12BatchIngestJSON do
  def created(%{batch: batch, edi_files: edi_files}) do
    %{
      status: "accepted",
      batch_id: batch.batch_id,
      source: batch.source,
      claims_ingested: length(edi_files),
      batch_db_id: batch.id,
      inserted_at: batch.inserted_at
    }
  end

  def show(%{batch: batch, summary: summary, edi_files: edi_files}) do
    %{
      batch_id: batch.batch_id,
      source: batch.source,
      status: batch.status,
      file_count: batch.file_count,
      started_at: batch.inserted_at,
      completed_at: batch.completed_at,
      summary: summary,
      files:
        Enum.map(edi_files, fn f ->
          %{
            id: f.id,
            filename: f.filename,
            status: f.status,
            risk: get_in(f.json_output, ["overallRisk"]),
            matched_rules: get_in(f.json_output, ["matchedRules"]),
            processed_at: f.processed_at
          }
        end)
    }
  end

  def error(%{reason: reason, changeset: changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{error: reason, details: errors}
  end
end
