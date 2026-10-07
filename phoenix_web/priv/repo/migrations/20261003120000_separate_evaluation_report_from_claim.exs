defmodule MedicaidClaimsChecker.Repo.Migrations.SeparateEvaluationReportFromClaim do
  @moduledoc """
  Keeps the translated claim and the engine's evaluation report in separate
  columns, and drops the automatic "fraudulent" file status.

  Previously the report overwrote `json_output` (the claim), and HighRisk /
  CriticalRisk claims were stored with status "fraudulent". A fraud
  determination belongs to an analyst, not the engine, so `status` is now a
  processing state only; risk lives in `evaluation_report`.
  """
  use Ecto.Migration

  def up do
    alter table(:edi_files) do
      add :evaluation_report, :map
    end

    flush()

    # Rows whose json_output holds an engine report (it has "overallRisk")
    # move it to evaluation_report. The original claim was not kept for
    # these rows, so json_output becomes NULL rather than staying mislabelled.
    execute """
    UPDATE edi_files
       SET evaluation_report = json_output,
           json_output = NULL
     WHERE json_output ? 'overallRisk'
    """

    execute "UPDATE edi_files SET status = 'evaluated' WHERE status = 'fraudulent'"
  end

  def down do
    execute """
    UPDATE edi_files
       SET status = 'fraudulent'
     WHERE status = 'evaluated'
       AND evaluation_report->>'overallRisk' IN ('HighRisk', 'CriticalRisk')
    """

    execute """
    UPDATE edi_files
       SET json_output = evaluation_report
     WHERE evaluation_report IS NOT NULL
    """

    alter table(:edi_files) do
      remove :evaluation_report
    end
  end
end
