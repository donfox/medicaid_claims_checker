# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.Ingestion.RemoteFetcher do
  @moduledoc """
  Fetches and extracts remote X12 batch archives from HTTP/HTTPS URLs.

  Supports:
  - ZIP archives containing X12 files (.x12, .edi, .txt)
  - Optional manifest.json for batch metadata
  - Automatic cleanup of temporary files
  - Configurable timeouts and file size limits

  ## Example

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.fetch_and_extract("https://example.com/batch.zip")
      {:ok, %{files: ["/tmp/x12bridge_remote_123/file1.x12"], manifest: nil, temp_dir: "/tmp/x12bridge_remote_123"}}

  """

  @compile {:no_warn_undefined, {:ssh, :start, 0}}
  @compile {:no_warn_undefined, {:ssh, :connect, 3}}
  @compile {:no_warn_undefined, {:ssh, :close, 1}}
  @compile {:no_warn_undefined, {:ssh_sftp, :start_channel, 1}}
  @compile {:no_warn_undefined, {:ssh_sftp, :stop_channel, 1}}
  @compile {:no_warn_undefined, {:ssh_sftp, :list_dir, 2}}
  @compile {:no_warn_undefined, {:ssh_sftp, :read_file, 2}}

  require Logger

  @doc """
  Fetches X12 files from various sources.

  Supports:
    * HTTP/HTTPS URLs (e.g., "https://example.com/batch.zip")
    * SFTP URLs (e.g., "sftp://user@host/path/to/files") - requires SFTP config
    * Local ZIP files (e.g., "/path/to/batch.zip")
    * Local directories (e.g., "/path/to/x12_files/")
    * Local single X12 files (e.g., "/path/to/claim.x12")
    * Databricks paths (e.g., "/mnt/data/x12/batch.zip") - requires Databricks config

  ## Options

    * `:timeout` - Download timeout in milliseconds (default: from config, 60s)
    * `:max_size` - Maximum file size in bytes (default: from config, 100MB)

  ## Returns

    * `{:ok, result}` where result contains:
      * `:files` - List of absolute paths to X12 files
      * `:manifest` - Parsed manifest.json map if present, nil otherwise
      * `:temp_dir` - Temporary directory path (caller must clean up via cleanup_temp_files/1)
                      For local directories/files, this is nil (no cleanup needed)
      * `:source_dir` - The source directory for output (where JSON should be written back)

    * `{:error, reason}` where reason is:
      * `:invalid_url` - URL format invalid or non-HTTP(S)
      * `:invalid_path` - Local file/directory path does not exist
      * `:download_failed` - Network error or timeout
      * `{:http_error, status_code}` - Non-200 HTTP response
      * `:invalid_zip` - Not a valid ZIP file
      * `:no_x12_files` - No X12 files found
      * `:file_too_large` - File exceeds max_size limit
      * `:databricks_not_configured` - Databricks API credentials not configured

  """
  def fetch_and_extract(source, opts \\ []) do
    case detect_source_type(source) do
      :http_url ->
        fetch_from_http(source, opts)

      :sftp_url ->
        fetch_from_sftp(source, opts)

      :local_directory ->
        fetch_from_local_directory(source, opts)

      :local_zip ->
        fetch_from_local_zip(source, opts)

      :local_x12_file ->
        fetch_from_local_x12(source, opts)

      :databricks_path ->
        fetch_from_databricks(source, opts)

      :invalid ->
        {:error, :invalid_url}
    end
  end

  @doc """
  Detects the type of source path provided.

  ## Examples

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.detect_source_type("https://example.com/file.zip")
      :http_url

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.detect_source_type("/Users/name/file.zip")
      :local_zip

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.detect_source_type("/Users/name/x12_files/")
      :local_directory

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.detect_source_type("/Users/name/claim.x12")
      :local_x12_file

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.detect_source_type("/mnt/data/x12/file.zip")
      :databricks_path

  """
  def detect_source_type(source) when is_binary(source) do
    cond do
      # HTTP/HTTPS URL
      String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
        :http_url

      # SFTP URL
      String.starts_with?(source, "sftp://") ->
        :sftp_url

      # Databricks mount path
      String.starts_with?(source, "/mnt/") or String.starts_with?(source, "dbfs:/") ->
        :databricks_path

      # Local path - determine if it's a directory, ZIP, or X12 file
      is_local_path?(source) ->
        detect_local_type(source)

      # Invalid (single words, empty strings, etc.)
      true ->
        :invalid
    end
  end

  def detect_source_type(_), do: :invalid

  # Check if source looks like a local file path
  defp is_local_path?(source) do
    # Absolute Unix path
    # Absolute Windows path
    # Relative path with separators
    String.starts_with?(source, "/") or
      String.match?(source, ~r/^[A-Za-z]:[\\\/]/) or
      String.contains?(source, "/") or String.contains?(source, "\\")
  end

  # Detect the specific type of local source
  defp detect_local_type(source) do
    cond do
      # Check if it's an existing directory
      File.dir?(source) ->
        :local_directory

      # Check if it's a ZIP file (by extension)
      String.ends_with?(String.downcase(source), ".zip") ->
        :local_zip

      # Check if it's an X12/EDI file (by extension)
      is_x12_extension?(source) ->
        :local_x12_file

      # If file exists but unknown extension, try to detect
      File.exists?(source) ->
        if File.dir?(source), do: :local_directory, else: :local_x12_file

      # Path doesn't exist yet - guess based on extension or trailing slash
      String.ends_with?(source, "/") or String.ends_with?(source, "\\") ->
        :local_directory

      true ->
        # Default to treating as a potential file path (will error if not found)
        :local_x12_file
    end
  end

  defp is_x12_extension?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in [".x12", ".edi", ".txt"]
  end

  # Fetch from HTTP/HTTPS URL
  defp fetch_from_http(url, opts) do
    with {:ok, _uri} <- validate_url(url),
         {:ok, config} <- get_config(opts),
         {:ok, zip_data} <- download_file(url, config.timeout, config.max_size),
         {:ok, temp_dir} <- create_temp_directory(),
         {:ok, extracted_files} <- extract_zip(zip_data, temp_dir),
         {:ok, x12_files} <- validate_zip_contents(extracted_files, config.allowed_extensions),
         {:ok, manifest} <- load_manifest(temp_dir) do
      {:ok,
       %{
         files: x12_files,
         manifest: manifest,
         temp_dir: temp_dir,
         # No local source directory for HTTP sources (output not written back)
         source_dir: nil
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  # Fetch from SFTP server
  defp fetch_from_sftp(sftp_url, opts) do
    Logger.info("Fetching from SFTP: #{sftp_url}")

    with {:ok, config} <- get_config(opts),
         {:ok, sftp_config} <- get_sftp_config(sftp_url, opts),
         {:ok, temp_dir} <- create_temp_directory(),
         {:ok, files} <- download_sftp_files(sftp_config, temp_dir, config) do
      # Check if we downloaded a ZIP or individual files
      zip_files = Enum.filter(files, &String.ends_with?(String.downcase(&1), ".zip"))

      if length(zip_files) == 1 do
        # Extract the ZIP
        zip_path = hd(zip_files)

        with {:ok, zip_data} <- File.read(zip_path),
             {:ok, extracted_files} <- extract_zip(zip_data, temp_dir),
             {:ok, x12_files} <- validate_zip_contents(extracted_files, config.allowed_extensions),
             {:ok, manifest} <- load_manifest(temp_dir) do
          File.rm(zip_path)

          {:ok,
           %{
             files: x12_files,
             manifest: manifest,
             temp_dir: temp_dir,
             source_dir: nil
           }}
        end
      else
        # Filter for X12 files directly
        x12_files =
          files
          |> Enum.filter(fn f ->
            String.downcase(Path.extname(f)) in config.allowed_extensions
          end)

        if Enum.empty?(x12_files) do
          cleanup_temp_files(temp_dir)
          {:error, :no_x12_files}
        else
          {:ok, manifest} = load_manifest(temp_dir)

          {:ok,
           %{
             files: x12_files,
             manifest: manifest,
             temp_dir: temp_dir,
             source_dir: nil
           }}
        end
      end
    else
      {:error, _reason} = error ->
        error
    end
  end

  # Parse SFTP URL and merge with environment config or passed options
  # Priority: passed options > URL components > environment config
  defp get_sftp_config(sftp_url, opts) do
    uri = URI.parse(sftp_url)

    # Get credentials from environment
    env_config = Application.get_env(:medicaid_claims_checker, :sftp, [])
    env_host = Keyword.get(env_config, :host)
    env_user = Keyword.get(env_config, :username)
    env_password = Keyword.get(env_config, :password)
    env_port = Keyword.get(env_config, :port, 22)

    # Get credentials from passed options (from UI form)
    opt_user = Keyword.get(opts, :sftp_username)
    opt_password = Keyword.get(opts, :sftp_password)
    opt_port = Keyword.get(opts, :sftp_port)

    # Priority: passed options > URL components > environment config
    host = uri.host || env_host
    user = non_empty(opt_user) || uri.userinfo || env_user
    port = opt_port || uri.port || env_port
    path = uri.path || "/"
    password = non_empty(opt_password) || env_password

    cond do
      is_nil(host) or host == "" ->
        Logger.error("SFTP host not configured. Use sftp://host/path URL format")
        {:error, :sftp_not_configured}

      is_nil(user) or user == "" ->
        Logger.error("SFTP username not configured. Enter username in the form")
        {:error, :sftp_not_configured}

      true ->
        {:ok,
         %{
           host: host,
           port: port,
           username: user,
           password: password,
           path: path
         }}
    end
  end

  # Helper to treat empty strings as nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(str) when is_binary(str), do: str

  # Download files from SFTP server
  defp download_sftp_files(sftp_config, temp_dir, config) do
    host = String.to_charlist(sftp_config.host)
    port = sftp_config.port
    user = String.to_charlist(sftp_config.username)

    password =
      case sftp_config.password do
        pw when is_binary(pw) and pw != "" -> String.to_charlist(pw)
        _ -> nil
      end

    remote_path = String.to_charlist(sftp_config.path)

    Logger.info("Connecting to SFTP: #{sftp_config.host}:#{port} as #{sftp_config.username}")

    # Start SSH application
    :ssh.start()

    connect_opts =
      [
        user: user,
        silently_accept_hosts: true,
        user_interaction: false,
        auth_methods: ~c"publickey,password",
        user_dir: String.to_charlist(Path.join(System.user_home!(), ".ssh")),
        connect_timeout: config.timeout
      ]
      |> maybe_put_password(password)

    case :ssh.connect(host, port, connect_opts) do
      {:ok, conn} ->
        Logger.info("SSH connected, starting SFTP channel")

        case :ssh_sftp.start_channel(conn) do
          {:ok, sftp_channel} ->
            result = download_from_channel(sftp_channel, remote_path, temp_dir, config)
            :ssh_sftp.stop_channel(sftp_channel)
            :ssh.close(conn)
            result

          {:error, reason} ->
            :ssh.close(conn)
            Logger.error("Failed to start SFTP channel: #{inspect(reason)}")
            {:error, :sftp_channel_failed}
        end

      {:error, reason} ->
        Logger.error("SSH connection failed: #{inspect(reason)}")
        {:error, :sftp_connection_failed}
    end
  end

  defp maybe_put_password(opts, nil), do: opts
  defp maybe_put_password(opts, password), do: Keyword.put(opts, :password, password)

  # Download files from SFTP channel
  defp download_from_channel(channel, remote_path, temp_dir, config) do
    case :ssh_sftp.list_dir(channel, remote_path) do
      {:ok, file_list} ->
        # It's a directory - download all matching files
        Logger.info("Remote path is directory, listing files...")

        files =
          file_list
          |> Enum.map(&to_string/1)
          |> Enum.reject(&(&1 in [".", ".."]))
          |> Enum.filter(fn name ->
            ext = Path.extname(name) |> String.downcase()
            ext in config.allowed_extensions or ext == ".zip"
          end)

        Logger.info("Found #{length(files)} matching files: #{inspect(files)}")

        downloaded =
          Enum.reduce_while(files, {:ok, []}, fn filename, {:ok, acc} ->
            remote_file = Path.join(to_string(remote_path), filename) |> String.to_charlist()
            local_file = Path.join(temp_dir, filename)

            case download_single_file(channel, remote_file, local_file) do
              :ok ->
                {:cont, {:ok, [local_file | acc]}}

              {:error, reason} ->
                Logger.error("Failed to download #{filename}: #{inspect(reason)}")
                {:cont, {:ok, acc}}
            end
          end)

        case downloaded do
          {:ok, []} -> {:error, :no_x12_files}
          {:ok, files} -> {:ok, Enum.reverse(files)}
        end

      {:error, :no_such_file} ->
        # It's a single file - download it directly
        filename = Path.basename(to_string(remote_path))
        local_file = Path.join(temp_dir, filename)

        case download_single_file(channel, remote_path, local_file) do
          :ok -> {:ok, [local_file]}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to list remote directory: #{inspect(reason)}")
        {:error, :sftp_list_failed}
    end
  end

  # Download a single file from SFTP
  defp download_single_file(channel, remote_path, local_path) do
    Logger.info("Downloading: #{remote_path} -> #{local_path}")

    case :ssh_sftp.read_file(channel, remote_path) do
      {:ok, data} ->
        File.write!(local_path, data)
        Logger.info("Downloaded #{byte_size(data)} bytes")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fetch from local ZIP file
  defp fetch_from_local_zip(file_path, opts) do
    Logger.info("Reading local ZIP file: #{file_path}")

    with {:ok, config} <- get_config(opts),
         {:ok, _} <- validate_local_file(file_path, config.max_size),
         {:ok, zip_data} <- File.read(file_path),
         {:ok, temp_dir} <- create_temp_directory(),
         {:ok, extracted_files} <- extract_zip(zip_data, temp_dir),
         {:ok, x12_files} <- validate_zip_contents(extracted_files, config.allowed_extensions),
         {:ok, manifest} <- load_manifest(temp_dir) do
      {:ok,
       %{
         files: x12_files,
         manifest: manifest,
         temp_dir: temp_dir,
         # Source directory is the directory containing the ZIP file
         source_dir: Path.expand(file_path) |> Path.dirname()
       }}
    else
      {:error, :enoent} ->
        Logger.error("Local ZIP file not found: #{file_path}")
        {:error, :invalid_path}

      {:error, _reason} = error ->
        error
    end
  end

  # Fetch from local directory containing X12 files
  defp fetch_from_local_directory(dir_path, opts) do
    Logger.info("Reading local directory: #{dir_path}")

    with {:ok, config} <- get_config(opts),
         {:ok, _} <- validate_local_directory(dir_path),
         {:ok, x12_files} <- find_x12_files_in_directory(dir_path, config.allowed_extensions),
         {:ok, manifest} <- load_manifest(dir_path) do
      {:ok,
       %{
         files: x12_files,
         manifest: manifest,
         # No cleanup needed for local directories
         temp_dir: nil,
         # Source directory for output
         source_dir: Path.expand(dir_path)
       }}
    else
      {:error, _reason} = error ->
        error
    end
  end

  # Fetch a single local X12 file
  defp fetch_from_local_x12(file_path, opts) do
    Logger.info("Reading local X12 file: #{file_path}")

    with {:ok, config} <- get_config(opts),
         {:ok, _} <- validate_local_file(file_path, config.max_size),
         true <- File.exists?(file_path) do
      {:ok,
       %{
         files: [Path.expand(file_path)],
         manifest: nil,
         # No cleanup needed for local files
         temp_dir: nil,
         # Source directory is the parent of the file
         source_dir: Path.expand(file_path) |> Path.dirname()
       }}
    else
      false ->
        Logger.error("Local X12 file not found: #{file_path}")
        {:error, :invalid_path}

      {:error, _reason} = error ->
        error
    end
  end

  # Validate that a local directory exists and is accessible
  defp validate_local_directory(dir_path) do
    cond do
      not File.exists?(dir_path) ->
        Logger.error("Directory not found: #{dir_path}")
        {:error, :invalid_path}

      not File.dir?(dir_path) ->
        Logger.error("Path is not a directory: #{dir_path}")
        {:error, :invalid_path}

      true ->
        {:ok, :valid}
    end
  end

  # Find all X12 files in a directory (non-recursive)
  defp find_x12_files_in_directory(dir_path, allowed_extensions) do
    case File.ls(dir_path) do
      {:ok, files} ->
        x12_files =
          files
          |> Enum.map(fn file -> Path.join(dir_path, file) end)
          |> Enum.filter(fn path ->
            File.regular?(path) &&
              String.downcase(Path.extname(path)) in allowed_extensions
          end)
          |> Enum.map(&Path.expand/1)
          |> Enum.sort()

        if Enum.empty?(x12_files) do
          Logger.error(
            "No X12 files found in directory. Expected extensions: #{inspect(allowed_extensions)}"
          )

          {:error, :no_x12_files}
        else
          Logger.info("Found #{length(x12_files)} X12 files in directory")
          {:ok, x12_files}
        end

      {:error, reason} ->
        Logger.error("Failed to list directory: #{inspect(reason)}")
        {:error, :invalid_path}
    end
  end

  # Fetch from Databricks (placeholder - requires API integration)
  defp fetch_from_databricks(databricks_path, opts) do
    Logger.info("Attempting to fetch from Databricks: #{databricks_path}")

    # Check if Databricks credentials are configured
    databricks_config = Application.get_env(:medicaid_claims_checker, :databricks, [])
    host = Keyword.get(databricks_config, :host)
    token = Keyword.get(databricks_config, :token)

    cond do
      is_nil(host) or is_nil(token) ->
        Logger.error("""
        Databricks not configured. Please set in config/runtime.exs:

        config :medicaid_claims_checker, :databricks,
          host: System.get_env("DATABRICKS_HOST"),
          token: System.get_env("DATABRICKS_TOKEN")
        """)

        {:error, :databricks_not_configured}

      true ->
        fetch_from_databricks_api(databricks_path, host, token, opts)
    end
  end

  defp fetch_from_databricks_api(databricks_path, host, token, opts) do
    # Convert /mnt/ path to DBFS path
    dbfs_path =
      if String.starts_with?(databricks_path, "/mnt/") do
        String.replace_prefix(databricks_path, "/mnt/", "/dbfs/mnt/")
      else
        databricks_path
      end

    # Use Databricks REST API to read file
    url = "https://#{host}/api/2.0/dbfs/read?path=#{URI.encode(dbfs_path)}"

    Logger.info("Fetching from Databricks API: #{url}")

    :inets.start()
    :ssl.start()

    config = opts[:config] || elem(get_config(opts), 1)

    request = {
      String.to_charlist(url),
      [{~c"Authorization", String.to_charlist("Bearer #{token}")}]
    }

    http_options = [
      timeout: config.timeout,
      ssl: [verify: :verify_none]
    ]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        # Databricks API returns base64-encoded data
        case Jason.decode(body) do
          {:ok, %{"data" => base64_data}} ->
            zip_data = Base.decode64!(base64_data)
            Logger.info("Downloaded #{byte_size(zip_data)} bytes from Databricks")

            # Process the ZIP file
            with {:ok, temp_dir} <- create_temp_directory(),
                 {:ok, extracted_files} <- extract_zip(zip_data, temp_dir),
                 {:ok, x12_files} <-
                   validate_zip_contents(extracted_files, config.allowed_extensions),
                 {:ok, manifest} <- load_manifest(temp_dir) do
              {:ok,
               %{
                 files: x12_files,
                 manifest: manifest,
                 temp_dir: temp_dir,
                 # No local source directory for Databricks (output not written back locally)
                 source_dir: nil
               }}
            end

          {:error, _reason} ->
            {:error, :invalid_databricks_response}
        end

      {:ok, {{_version, status_code, _status}, _headers, _body}} ->
        Logger.error("Databricks API error: #{status_code}")
        {:error, {:databricks_error, status_code}}

      {:error, reason} ->
        Logger.error("Databricks fetch failed: #{inspect(reason)}")
        {:error, :download_failed}
    end
  end

  defp validate_local_file(file_path, max_size) do
    cond do
      not File.exists?(file_path) ->
        {:error, :invalid_path}

      not File.regular?(file_path) ->
        {:error, :invalid_path}

      File.stat!(file_path).size > max_size ->
        {:error, :file_too_large}

      true ->
        {:ok, :valid}
    end
  end

  @doc """
  Validates that a URL is well-formed and uses HTTP or HTTPS scheme.

  ## Examples

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.validate_url("https://example.com/file.zip")
      {:ok, %URI{scheme: "https", host: "example.com", ...}}

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.validate_url("ftp://example.com/file.zip")
      {:error, :invalid_url}

  """
  def validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and not is_nil(host) and host != "" ->
        {:ok, URI.parse(url)}

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  @doc """
  Removes temporary directory and all its contents.

  ## Examples

      iex> MedicaidClaimsChecker.Ingestion.RemoteFetcher.cleanup_temp_files("/tmp/x12bridge_remote_123")
      :ok

  """
  def cleanup_temp_files(temp_dir) when is_binary(temp_dir) do
    if File.exists?(temp_dir) do
      File.rm_rf!(temp_dir)
      Logger.debug("Cleaned up temporary directory: #{temp_dir}")
    end

    :ok
  end

  def cleanup_temp_files(_), do: :ok

  # Private functions

  defp get_config(opts) do
    app_config = Application.get_env(:medicaid_claims_checker, :remote_fetcher, [])

    config = %{
      timeout: Keyword.get(opts, :timeout, Keyword.get(app_config, :download_timeout_ms, 60_000)),
      max_size:
        Keyword.get(opts, :max_size, Keyword.get(app_config, :max_file_size_bytes, 100_000_000)),
      allowed_extensions:
        Keyword.get(
          opts,
          :allowed_extensions,
          Keyword.get(app_config, :allowed_extensions, [".x12", ".edi", ".txt"])
        )
    }

    {:ok, config}
  end

  defp download_file(url, timeout, max_size) do
    Logger.info("Downloading remote batch file from: #{url}")

    # Start required applications
    :inets.start()
    :ssl.start()

    request = {
      String.to_charlist(url),
      []
    }

    http_options = [
      timeout: timeout,
      ssl: [verify: :verify_none]
    ]

    body_format_options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, body_format_options) do
      {:ok, {{_version, 200, _status}, headers, body}} ->
        # Check file size
        content_length = get_content_length(headers)

        cond do
          content_length && content_length > max_size ->
            {:error, :file_too_large}

          byte_size(body) > max_size ->
            {:error, :file_too_large}

          true ->
            Logger.info("Downloaded #{byte_size(body)} bytes")
            {:ok, body}
        end

      {:ok, {{_version, status_code, _status}, _headers, _body}} ->
        Logger.error("HTTP error: #{status_code}")
        {:error, {:http_error, status_code}}

      {:error, reason} ->
        Logger.error("Download failed: #{inspect(reason)}")
        {:error, :download_failed}
    end
  end

  defp get_content_length(headers) do
    case Enum.find(headers, fn {key, _value} ->
           String.downcase(to_string(key)) == "content-length"
         end) do
      {_key, value} when is_list(value) ->
        value |> to_string() |> String.to_integer()

      {_key, value} when is_binary(value) ->
        String.to_integer(value)

      _ ->
        nil
    end
  end

  defp create_temp_directory do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    temp_dir = Path.join(System.tmp_dir!(), "x12bridge_remote_#{timestamp}_#{random}")

    case File.mkdir_p(temp_dir) do
      :ok ->
        Logger.debug("Created temporary directory: #{temp_dir}")
        {:ok, temp_dir}

      {:error, reason} ->
        Logger.error("Failed to create temp directory: #{inspect(reason)}")
        {:error, :temp_dir_failed}
    end
  end

  defp extract_zip(zip_data, extract_dir) when is_binary(zip_data) do
    # Write ZIP to temporary file (required by :zip.unzip)
    temp_zip = Path.join(extract_dir, "download.zip")

    with :ok <- File.write(temp_zip, zip_data),
         {:ok, files} <- unzip_file(temp_zip, extract_dir) do
      # Remove the temporary ZIP file
      File.rm(temp_zip)

      # Convert charlist paths to strings
      string_files =
        files
        |> Enum.map(&to_string/1)
        |> Enum.filter(&File.regular?/1)

      Logger.info("Extracted #{length(string_files)} files from ZIP")
      {:ok, string_files}
    else
      {:error, _reason} ->
        {:error, :invalid_zip}
    end
  end

  defp unzip_file(zip_path, extract_dir) do
    case :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(extract_dir)) do
      {:ok, files} ->
        {:ok, files}

      {:error, reason} ->
        Logger.error("ZIP extraction failed: #{inspect(reason)}")
        {:error, :invalid_zip}
    end
  end

  defp validate_zip_contents(files, allowed_extensions) do
    x12_files =
      Enum.filter(files, fn file ->
        ext = Path.extname(file) |> String.downcase()
        ext in allowed_extensions
      end)

    if Enum.empty?(x12_files) do
      Logger.error(
        "No X12 files found. Expected extensions: #{inspect(allowed_extensions)}, found: #{inspect(Enum.map(files, &Path.extname/1))}"
      )

      {:error, :no_x12_files}
    else
      Logger.info("Found #{length(x12_files)} X12 files")
      {:ok, x12_files}
    end
  end

  defp load_manifest(temp_dir) do
    manifest_path = Path.join(temp_dir, "manifest.json")

    case File.read(manifest_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} ->
            Logger.info("Loaded manifest.json")
            {:ok, manifest}

          {:error, _reason} ->
            Logger.warning("manifest.json found but could not be parsed")
            {:ok, nil}
        end

      {:error, _reason} ->
        # No manifest is fine
        {:ok, nil}
    end
  end
end
