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

  # Columns are found by their header names in the NPPES dissemination CSV,
  # so a change in CMS's column order cannot shift data into the wrong field.
  # (Fixed positions did: state was read from the second address line and
  # the deactivation date from the reactivation column.)
  @columns %{
    npi: "NPI",
    entity_type: "Entity Type Code",
    org_name: "Provider Organization Name (Legal Business Name)",
    last_name: "Provider Last Name (Legal Name)",
    first_name: "Provider First Name",
    credential: "Provider Credential Text",
    practice_state: "Provider Business Practice Location Address State Name",
    enumeration_date: "Provider Enumeration Date",
    last_update_date: "Last Update Date",
    deactivation_date: "NPI Deactivation Date",
    reactivation_date: "NPI Reactivation Date",
    taxonomy: "Healthcare Provider Taxonomy Code_1"
  }

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
      with {:ok, cols} <- read_columns(path) do
        import_rows(path, cols, now, on_progress)
      end
    rescue
      e ->
        Logger.error("NPPES: Import failed — #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp read_columns(path) do
    path
    |> File.stream!(read_ahead: 128 * 1024)
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
    |> Enum.take(1)
    |> case do
      [header] -> column_indices(header)
      [] -> {:error, "NPPES file is empty"}
    end
  end

  @doc false
  # Maps each needed field to its position in `header`, or names the
  # missing columns.
  def column_indices(header) do
    positions =
      header
      |> Enum.map(&(&1 |> String.replace_prefix("\uFEFF", "") |> String.trim()))
      |> Enum.with_index()
      |> Map.new()

    {found, missing} =
      Enum.reduce(@columns, {%{}, []}, fn {field, name}, {found, missing} ->
        case Map.fetch(positions, name) do
          {:ok, index} -> {Map.put(found, field, index), missing}
          :error -> {found, [name | missing]}
        end
      end)

    case missing do
      [] -> {:ok, found}
      _ -> {:error, "NPPES file is missing columns: #{missing |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  defp import_rows(path, cols, now, on_progress) do
    {count, _} =
      path
      |> File.stream!(read_ahead: 128 * 1024)
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
      |> Stream.map(&parse_row(&1, cols, now))
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
  end

  # --- Row parsing (extracted from Mix.Tasks.Nppes.Import) ---

  @doc false
  def parse_row(row, cols, now) do
    col = fn field -> safe_col(row, Map.fetch!(cols, field)) end
    npi = col.(:npi)

    if npi == nil or String.length(npi) != 10 do
      nil
    else
      entity_type = parse_entity_type(col.(:entity_type))

      provider_name =
        case entity_type do
          2 ->
            col.(:org_name) || "Unknown Organization"

          _ ->
            last = col.(:last_name) || ""
            first = col.(:first_name) || ""
            name = String.trim("#{last}, #{first}", ", ")
            if name == "", do: "Unknown Provider", else: name
        end

      %{
        npi: npi,
        entity_type: entity_type,
        provider_name: provider_name,
        credential: col.(:credential),
        taxonomy: col.(:taxonomy),
        state: col.(:practice_state),
        enumeration_date: parse_date(col.(:enumeration_date)),
        deactivation_date: parse_date(col.(:deactivation_date)),
        reactivation_date: parse_date(col.(:reactivation_date)),
        last_update_date: parse_date(col.(:last_update_date)),
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
