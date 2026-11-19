defmodule Mix.Tasks.Nppes.Import do
  @moduledoc """
  Imports the NPPES NPI bulk download CSV into the `nppes_providers` table.

  ## Usage

      mix nppes.import /path/to/npidata_pfile.csv

  The CSV (about 10 GB for the monthly full file) is streamed in batches of
  5,000 rows. Rows are upserted by NPI, so running the task again with a
  newer file is safe.

  The app is started without the timed NPPES refresh and without the
  scheduled-fetch poller, so neither runs inside this task (a timed refresh
  would start its own full download alongside the import).

  A full replacement file (`npidata_pfile_20050523-*.csv`) also marks NPIs
  it no longer lists with `dropped_on`; they are kept so late claims for
  earlier services can still be checked. Weekly update files never do.

  ## NPPES download

  Download the monthly "Full Replacement" file from:
  https://download.cms.gov/nppes/NPI_Files.html
  """

  use Mix.Task

  @shortdoc "Import NPPES NPI registry CSV into nppes_providers table"

  @impl Mix.Task
  def run([path]) do
    Application.put_env(:medicaid_claims_checker, MedicaidClaimsChecker.Nppes.RefreshWorker,
      scheduled: false
    )

    Application.put_env(
      :medicaid_claims_checker,
      :config_poller,
      Keyword.put(
        Application.get_env(:medicaid_claims_checker, :config_poller, []),
        :enabled,
        false
      )
    )

    Mix.Task.run("app.start")

    Mix.shell().info("Starting NPPES import from #{path} ...")

    case MedicaidClaimsChecker.Nppes.Importer.import_from_file(path) do
      {:ok, count} ->
        Mix.shell().info("Done. #{count} providers imported into nppes_providers.")

      {:error, reason} ->
        Mix.raise("NPPES import failed: #{reason}")
    end
  end

  def run(_) do
    Mix.raise("Usage: mix nppes.import /path/to/npidata_pfile.csv")
  end
end
