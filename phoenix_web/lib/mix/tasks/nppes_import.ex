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

  @batch_size 5_000
  @progress_interval 100_000

  # Column indices in the NPPES dissemination CSV (0-based).
  # These are stable across monthly releases.
  @col_npi 0
  @col_entity_type 1
  @col_org_name 4
  @col_last_name 5
  @col_first_name 6
  @col_credential 10
  @col_practice_state 29
  @col_enumeration_date 36
  @col_last_update_date 37
  @col_deactivation_date 40
  @col_reactivation_date 41

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    unless File.exists?(path) do
      Mix.raise("File not found: #{path}")
    end

    Mix.shell().info("Starting NPPES import from #{path} ...")

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      path
      |> File.stream!(read_ahead: 128 * 1024)
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
      |> Stream.map(&parse_row(&1, now))
      |> Stream.reject(&is_nil/1)
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce({0, 0}, fn batch, {total, _} ->
        MedicaidClaimsChecker.Repo.insert_all(
          MedicaidClaimsChecker.Claims.NppesProvider,
          batch,
          on_conflict: {:replace_all_except, [:npi]},
          conflict_target: [:npi]
        )

        new_total = total + length(batch)

        if rem(new_total, @progress_interval) < @batch_size do
          Mix.shell().info("  ... #{new_total} rows imported")
        end

        {new_total, 0}
      end)

    Mix.shell().info("Done. #{count} providers imported into nppes_providers.")
  end

  def run(_) do
    Mix.raise("Usage: mix nppes.import /path/to/npidata_pfile.csv")
  end

  defp parse_row(row, now) do
    npi = safe_col(row, @col_npi)

    if npi == nil or String.length(npi) != 10 do
      nil
    else
      entity_type = parse_entity_type(safe_col(row, @col_entity_type))

      provider_name =
        case entity_type do
          2 -> safe_col(row, @col_org_name) || "Unknown Organization"
          _ ->
            last = safe_col(row, @col_last_name) || ""
            first = safe_col(row, @col_first_name) || ""
            name = String.trim("#{last}, #{first}", ", ")
            if name == "", do: "Unknown Provider", else: name
        end

      %{
        npi: npi,
        entity_type: entity_type,
        provider_name: provider_name,
        credential: safe_col(row, @col_credential),
        state: safe_col(row, @col_practice_state),
        enumeration_date: parse_date(safe_col(row, @col_enumeration_date)),
        deactivation_date: parse_date(safe_col(row, @col_deactivation_date)),
        reactivation_date: parse_date(safe_col(row, @col_reactivation_date)),
        last_update_date: parse_date(safe_col(row, @col_last_update_date)),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp safe_col(row, index) do
    case Enum.at(row, index) do
      nil -> nil
      val ->
        trimmed = String.trim(val)
        if trimmed == "", do: nil, else: trimmed
    end
  end

  defp parse_entity_type("1"), do: 1
  defp parse_entity_type("2"), do: 2
  defp parse_entity_type(_), do: 1

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} ->
        # NPPES sometimes uses MM/DD/YYYY format
        case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4})$/, str) do
          [_, m, d, y] ->
            case Date.from_iso8601("#{y}-#{m}-#{d}") do
              {:ok, date} -> date
              _ -> nil
            end

          _ -> nil
        end
    end
  end
end
