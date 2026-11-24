defmodule MedicaidClaimsChecker.Ingestion.FetchRunner do
  @moduledoc """
  Executed by Quantum when a fetch schedule fires.

  Fetches remote files from the configured source, translates X12 claims
  to semantic JSON in-process, and ingests the resulting batch locally.

  A file the source has fetched before (same name, same bytes) is skipped,
  so files left in place aren't refused as duplicates on every run. A file
  is recorded as fetched once its batch is ingested; if ingestion fails it
  is tried again on the next run.

  A file that can't be read (truncated, not X12, ...) and a split claim that
  can't be converted are stored on the batch as `rejected_files`, so Jobs
  History shows them. When nothing in the run can be read, the batch is
  recorded as failed with only those rejections.
  """

  require Logger

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Fingerprint
  alias MedicaidClaimsChecker.Ingestion
  alias MedicaidClaimsChecker.Ingestion.RemoteFetcher
  alias MedicaidClaimsChecker.X12.FileClaims

  def run(source_config) when is_map(source_config) do
    uri = source_config["uri"] || source_config[:uri]
    name = source_config["name"] || source_config[:name] || "unnamed_source"
    source_type = source_config["source_type"] || source_config[:source_type] || "unknown"

    Logger.info("Running scheduled fetch for '#{name}' (#{source_type}) from #{uri}")

    # Decrypt credentials at execution time — the Quantum job closure stores
    # only the source ID, keeping plaintext out of the scheduler's job table.
    source_id = source_config[:id] || source_config["id"]

    credentials =
      case source_id && Ingestion.get_fetch_source(source_id) do
        %{credentials: creds} -> creds || %{}
        _ -> %{}
      end

    source_config = Map.put(source_config, :credentials, credentials)
    opts = build_fetch_opts(source_config)

    case RemoteFetcher.fetch_and_extract(uri, opts) do
      {:ok, %{files: files, temp_dir: temp_dir}} ->
        Logger.info("Fetched #{length(files)} file(s) from '#{name}'")

        ingest_result = process_files(source_id, name, files)

        if temp_dir, do: RemoteFetcher.cleanup_temp_files(temp_dir)

        ingest_result

      {:error, reason} ->
        Logger.error("Fetch failed for '#{name}': #{inspect(reason)}")
        {:error, reason}
    end
  end

  def run(_), do: {:error, :invalid_source_config}

  defp process_files(source_id, source_name, files) do
    read = Enum.flat_map(files, &read_file/1)
    keys = Enum.map(read, fn {name, _content, sha} -> {name, sha} end)
    seen = if source_id, do: Ingestion.already_fetched(source_id, keys), else: MapSet.new()
    new = Enum.reject(read, fn {name, _content, sha} -> MapSet.member?(seen, {name, sha}) end)

    if MapSet.size(seen) > 0 do
      Logger.info("Skipped #{MapSet.size(seen)} file(s) already fetched from '#{source_name}'")
    end

    if new == [] do
      {:ok, :nothing_new}
    else
      result = ingest_files(source_name, new)

      if source_id && match?({:ok, _}, result) do
        Ingestion.record_fetched(
          source_id,
          Enum.map(new, fn {name, _content, sha} -> {name, sha} end)
        )
      end

      result
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        [{Path.basename(path), content, Fingerprint.file(content)}]

      {:error, reason} ->
        Logger.warning("Failed to read #{Path.basename(path)}: #{inspect(reason)}")
        []
    end
  end

  defp ingest_files(source_name, files) do
    {claims, rejected} =
      files
      |> Enum.map(&claims_for_file/1)
      |> Enum.reduce({[], []}, fn {c, r}, {ca, ra} -> {ca ++ c, ra ++ r} end)

    Enum.each(rejected, &Logger.warning("Rejected #{&1["filename"]}: #{&1["reason"]}"))

    if claims == [] and rejected == [] do
      Logger.error("No claims produced from fetched files")
      {:error, :no_claims_produced}
    else
      batch_id = "sched_#{System.system_time(:millisecond)}"

      payload = %{
        "batch_id" => batch_id,
        "source" => "scheduled:#{source_name}",
        "batch_name" => "Scheduled: #{source_name}",
        "claims" => claims,
        "rejected_files" => rejected
      }

      Claims.ingest_batch(payload)
    end
  end

  # {claims, rejected} for one fetched file.
  defp claims_for_file({filename, content, _sha}), do: FileClaims.claims(filename, content)

  defp build_fetch_opts(source_config) do
    creds = source_config["credentials"] || source_config[:credentials] || %{}
    uri = source_config["uri"] || source_config[:uri] || ""

    password = creds["password"] || creds[:password]
    username = creds["username"] || creds[:username] || extract_username_from_uri(uri)

    cond do
      password && username -> [sftp_username: username, sftp_password: password]
      username -> [sftp_username: username]
      password -> [sftp_password: password]
      true -> []
    end
  end

  defp extract_username_from_uri(uri) do
    case Regex.run(~r{://([^@]+)@}, uri) do
      [_, user] -> user
      _ -> nil
    end
  end
end
