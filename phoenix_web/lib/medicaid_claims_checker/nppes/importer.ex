defmodule MedicaidClaimsChecker.Nppes.Importer do
  @moduledoc """
  Imports NPPES NPI bulk download data into the `nppes_providers` table.

  Provides two entry points:
  - `import_from_file/2` — streams a local CSV file
  - `download_and_import/1` — downloads ZIP from CMS, extracts CSV, imports it
  """

  alias MedicaidClaimsChecker.Repo
  alias MedicaidClaimsChecker.Claims.NppesProvider

  require Logger

  @batch_size 5_000
  @progress_interval 100_000

  # Column indices in the NPPES dissemination CSV (0-based).
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

  @doc """
  Imports NPPES providers from a local CSV file.

  Options:
  - `:on_progress` — `fn rows_imported -> ... end` called every #{@progress_interval} rows

  Returns `{:ok, row_count}` or `{:error, reason}`.
  """
  def import_from_file(path, opts \\ []) do
    unless File.exists?(path) do
      {:error, "File not found: #{path}"}
    else
      do_import(path, opts)
    end
  end

  @doc """
  Downloads the NPPES ZIP from the given URL, extracts the CSV, and imports it.

  Returns `{:ok, row_count}` or `{:error, reason}`.
  """
  def download_and_import(url, opts \\ []) do
    tmp_dir = Path.join(System.tmp_dir!(), "nppes_#{System.system_time(:second)}")
    File.mkdir_p!(tmp_dir)
    zip_path = Path.join(tmp_dir, "nppes.zip")

    try do
      with :ok <- download_file(url, zip_path),
           {:ok, csv_path} <- extract_csv(zip_path, tmp_dir) do
        import_from_file(csv_path, opts)
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  # --- Download helpers ---

  defp download_file(url, dest) do
    Logger.info("NPPES: Downloading from #{url}")

    case Req.get(url, into: File.stream!(dest), receive_timeout: 600_000) do
      {:ok, %{status: 200}} ->
        Logger.info("NPPES: Download complete (#{File.stat!(dest).size} bytes)")
        :ok

      {:ok, %{status: status}} ->
        {:error, "Download failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp extract_csv(zip_path, dest_dir) do
    Logger.info("NPPES: Extracting ZIP")

    case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(dest_dir)}]) do
      {:ok, files} ->
        csv_file =
          files
          |> Enum.map(&to_string/1)
          |> Enum.find(&String.ends_with?(&1, ".csv"))

        if csv_file do
          Logger.info("NPPES: Found CSV #{Path.basename(csv_file)}")
          {:ok, csv_file}
        else
          {:error, "No CSV file found in ZIP archive"}
        end

      {:error, reason} ->
        {:error, "Failed to extract ZIP: #{inspect(reason)}"}
    end
  end

  # --- CSV import ---

  defp do_import(path, opts) do
    on_progress = Keyword.get(opts, :on_progress, fn _count -> :ok end)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Logger.info("NPPES: Starting import from #{path}")

    try do
      {count, _} =
        path
        |> File.stream!(read_ahead: 128 * 1024)
        |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
        |> Stream.map(&parse_row(&1, now))
        |> Stream.reject(&is_nil/1)
        |> Stream.chunk_every(@batch_size)
        |> Enum.reduce({0, 0}, fn batch, {total, _} ->
          Repo.insert_all(
            NppesProvider,
            batch,
            on_conflict: {:replace_all_except, [:npi]},
            conflict_target: [:npi]
          )

          new_total = total + length(batch)

          if rem(new_total, @progress_interval) < @batch_size do
            Logger.info("NPPES: #{new_total} rows imported")
            on_progress.(new_total)
          end

          {new_total, 0}
        end)

      Logger.info("NPPES: Import complete — #{count} providers")
      {:ok, count}
    rescue
      e ->
        Logger.error("NPPES: Import failed — #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # --- Row parsing (extracted from Mix.Tasks.Nppes.Import) ---

  defp parse_row(row, now) do
    npi = safe_col(row, @col_npi)

    if npi == nil or String.length(npi) != 10 do
      nil
    else
      entity_type = parse_entity_type(safe_col(row, @col_entity_type))

      provider_name =
        case entity_type do
          2 ->
            safe_col(row, @col_org_name) || "Unknown Organization"

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
      nil ->
        nil

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
      {:ok, date} ->
        date

      {:error, _} ->
        case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4})$/, str) do
          [_, m, d, y] ->
            case Date.from_iso8601("#{y}-#{m}-#{d}") do
              {:ok, date} -> date
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end
end
