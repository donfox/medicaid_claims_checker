defmodule MedicaidClaimsChecker.Ingestion.FetchRunner do
  @moduledoc """
  Executed by Quantum when a fetch schedule fires.

  Fetches remote files from the configured source, translates X12 claims
  to semantic JSON in-process, and ingests the resulting batch locally.
  """

  require Logger

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Ingestion.RemoteFetcher
  alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}

  def run(source_config) when is_map(source_config) do
    uri = source_config["uri"] || source_config[:uri]
    name = source_config["name"] || source_config[:name] || "unnamed_source"
    source_type = source_config["source_type"] || source_config[:source_type] || "unknown"

    Logger.info("Running scheduled fetch for '#{name}' (#{source_type}) from #{uri}")

    opts = build_fetch_opts(source_config)

    case RemoteFetcher.fetch_and_extract(uri, opts) do
      {:ok, %{files: files, temp_dir: temp_dir}} ->
        Logger.info("Fetched #{length(files)} file(s) from '#{name}'")

        ingest_result = process_files(name, files)

        if temp_dir, do: RemoteFetcher.cleanup_temp_files(temp_dir)

        ingest_result

      {:error, reason} ->
        Logger.error("Fetch failed for '#{name}': #{inspect(reason)}")
        {:error, reason}
    end
  end

  def run(_), do: {:error, :invalid_source_config}

  defp process_files(source_name, files) do
    claims =
      files
      |> Enum.flat_map(&claims_for_file/1)

    if claims == [] do
      Logger.error("No claims produced from fetched files")
      {:error, :no_claims_produced}
    else
      batch_id = "sched_#{System.system_time(:millisecond)}"

      payload = %{
        "batch_id" => batch_id,
        "source" => "scheduled:#{source_name}",
        "batch_name" => "Scheduled: #{source_name}",
        "claims" => claims
      }

      Claims.ingest_batch(payload)
    end
  end

  defp claims_for_file(path) do
    filename = Path.basename(path)

    with {:ok, content} <- File.read(path),
         {:ok, tx_sets} <- ClaimSplitter.split_transaction_sets(content) do
      parts = if is_list(tx_sets), do: tx_sets, else: [content]
      Enum.flat_map(parts, &claims_for_transaction_set(filename, &1))
    else
      {:error, reason} ->
        Logger.warning("Failed to process #{filename}: #{inspect(reason)}")
        []
    end
  end

  defp claims_for_transaction_set(filename, content) do
    case ClaimSplitter.split_claims_to_x12(content) do
      {:ok, nil} ->
        case translate_x12(content) do
          {:ok, claim} ->
            [%{"filename" => to_json_filename(filename), "claim" => claim}]

          {:error, reason} ->
            Logger.warning("Translation failed for #{filename}: #{inspect(reason)}")
            []
        end

      {:ok, claims} when is_list(claims) ->
        Enum.flat_map(claims, fn %{claim_id: claim_id, x12_content: claim_x12} ->
          case translate_x12(claim_x12) do
            {:ok, claim} ->
              [%{"filename" => to_split_filename(filename, claim_id), "claim" => claim}]

            {:error, reason} ->
              Logger.warning(
                "Translation failed for split claim #{claim_id} in #{filename}: #{inspect(reason)}"
              )

              []
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to split claims for #{filename}: #{inspect(reason)}")
        []
    end
  end

  defp translate_x12(x12_content) do
    with {:ok, flat_json} <- Converter.convert_content(x12_content),
         {:ok, semantic} <- SegmentMapper.map_from_json(flat_json) do
      {:ok, semantic}
    end
  end

  defp to_json_filename(original_filename) do
    root = Path.rootname(original_filename)
    root <> ".json"
  end

  defp to_split_filename(original_filename, claim_id) do
    root = Path.rootname(original_filename)
    "#{root}_#{claim_id}.json"
  end

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
