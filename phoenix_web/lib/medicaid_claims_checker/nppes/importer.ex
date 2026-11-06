defmodule MedicaidClaimsChecker.Nppes.Importer do
  @moduledoc """
  Imports NPPES NPI bulk download data into the `nppes_providers` table.

  Provides two entry points:
  - `import_from_file/2` — streams a local CSV file
  - `download_and_import/1` — downloads ZIP from CMS, extracts CSV, imports it
  """

  import Ecto.Query

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
  - `:full_file` — whether the file lists every NPI (CMS's monthly full
    replacement file). Defaults to true for files named like CMS's full file
    (`npidata_pfile_20050523-*.csv`). After a full import, NPIs missing from
    the file get `dropped_on` set to today; they are kept, never deleted,
    because late claims for services before the drop must still be checked.
    A weekly update file lists only changes, so it never marks NPIs dropped.

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
    tmp_dir = Keyword.get_lazy(opts, :tmp_dir, &new_tmp_dir/0)
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

  @tmp_prefix "nppes_"

  @doc """
  A fresh path for one refresh's download and unzipped files (not created).
  The refresh worker passes it as `:tmp_dir`, so it can delete the folder
  itself when a refresh is cancelled: a killed import never reaches the
  `after` clause that normally removes it.
  """
  def new_tmp_dir(parent \\ System.tmp_dir!()) do
    Path.join(parent, "#{@tmp_prefix}#{System.system_time(:millisecond)}")
  end

  @doc """
  Deletes refresh folders left by imports that were cancelled or crashed:
  every `nppes_*` folder in `parent` whose newest file is older than
  `max_age_seconds`, so a download still in progress is never touched.
  Returns the paths removed.
  """
  def remove_stale_tmp_dirs(parent \\ System.tmp_dir!(), max_age_seconds \\ 3600) do
    cutoff = System.os_time(:second) - max_age_seconds

    parent
    |> Path.join(@tmp_prefix <> "*")
    |> Path.wildcard()
    |> Enum.filter(&(File.dir?(&1) and newest_mtime(&1) < cutoff))
    |> Enum.map(fn dir ->
      File.rm_rf!(dir)
      Logger.info("NPPES: removed leftover refresh folder #{dir}")
      dir
    end)
  end

  defp newest_mtime(dir) do
    [dir | Path.wildcard(Path.join(dir, "**"))]
    |> Enum.map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> 0
      end
    end)
    |> Enum.max()
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
        case files |> Enum.map(&to_string/1) |> provider_csv() do
          nil ->
            {:error, "No npidata_pfile CSV found in ZIP archive"}

          csv_file ->
            Logger.info("NPPES: Found CSV #{Path.basename(csv_file)}")
            {:ok, csv_file}
        end

      {:error, reason} ->
        {:error, "Failed to extract ZIP: #{inspect(reason)}"}
    end
  end

  @doc false
  # The CMS zip holds several CSVs (npidata, othername, endpoint, pl) plus a
  # _fileheader.csv for each; the providers are in npidata_pfile_*.csv.
  def provider_csv(paths) do
    Enum.find(paths, fn path ->
      name = Path.basename(path)

      String.starts_with?(name, "npidata_pfile") and String.ends_with?(name, ".csv") and
        not String.ends_with?(name, "_fileheader.csv")
    end)
  end

  # --- CSV import ---

  defp do_import(path, opts) do
    on_progress = Keyword.get(opts, :on_progress, fn _count -> :ok end)
    full_file? = Keyword.get_lazy(opts, :full_file, fn -> full_file_name?(path) end)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Logger.info("NPPES: Starting import from #{path}")

    try do
      with {:ok, cols} <- read_columns(path),
           {:ok, count} <- import_rows(path, cols, now, on_progress) do
        if full_file?, do: mark_dropped(now)
        {:ok, count}
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
  # CMS names the monthly full replacement file npidata_pfile_20050523-<end>.csv
  # (its data starts with NPPES itself); weekly update files start later.
  def full_file_name?(path),
    do: path |> Path.basename() |> String.starts_with?("npidata_pfile_20050523-")

  # Every NPI in the file was just upserted with updated_at = now, so older
  # rows are NPIs CMS no longer lists. Only the first missing import sets the
  # date; an NPI that reappears is cleared by its upsert (dropped_on: nil).
  defp mark_dropped(now) do
    {dropped, _} =
      from(p in NppesProvider, where: p.updated_at < ^now and is_nil(p.dropped_on))
      |> Repo.update_all([set: [dropped_on: DateTime.to_date(now)]], timeout: :infinity)

    Logger.info(
      "NPPES: #{dropped} NPI(s) no longer in the file marked dropped (kept for late claims)"
    )
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
        dropped_on: nil,
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
