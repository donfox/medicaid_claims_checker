defmodule Mix.Tasks.Nppes.Import do
  @moduledoc """
  Imports the NPPES NPI bulk download CSV into the `nppes_providers` table.

  ## Usage

      mix nppes.import /path/to/npidata_pfile.csv

  The CSV is streamed in batches of 5,000 rows to avoid loading the full
  ~4 GB file into memory. Uses upsert (`on_conflict: :replace_all`) so
  running the task again with a newer monthly file is safe and idempotent.

  ## NPPES download

  Download the monthly "Full Replacement" file from:
  https://download.cms.gov/nppes/NPI_Files.html
  """

  use Mix.Task

  @shortdoc "Import NPPES NPI registry CSV into nppes_providers table"

  @impl Mix.Task
  def run([path]) do
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
