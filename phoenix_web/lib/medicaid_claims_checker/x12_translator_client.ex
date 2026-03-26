defmodule MedicaidClaimsChecker.X12TranslatorClient do
  @moduledoc """
  HTTP client for submitting X12 EDI files to X12Translator's REST API.

  Files are submitted for asynchronous translation. X12Translator processes
  them through verify → translate and delivers results via webhook to
  `/api/x12-batch-ingest`.
  """

  require Logger

  @doc """
  Submits one or more X12 files to X12Translator for translation.

  Accepts a list of `{filename, binary_content}` tuples.
  Returns `{:ok, %{batch_id: id, file_count: n}}` on acceptance.
  """
  def submit_files(files) when is_list(files) do
    url = "#{base_url()}/api/translate"
    boundary = "----ElixirMultipart#{:erlang.unique_integer([:positive])}"

    body =
      files
      |> Enum.map(fn {filename, content} ->
        "--#{boundary}\r\n" <>
          "Content-Disposition: form-data; name=\"files[]\"; filename=\"#{filename}\"\r\n" <>
          "Content-Type: application/octet-stream\r\n" <>
          "\r\n" <>
          content <> "\r\n"
      end)
      |> Enum.join()
      |> Kernel.<>("--#{boundary}--\r\n")

    headers = [{"Content-Type", "multipart/form-data; boundary=#{boundary}"}]

    Logger.info("Submitting #{length(files)} file(s) to X12Translator at #{url}")

    case HTTPoison.post(url, body, headers, timeout: 30_000, recv_timeout: 30_000) do
      {:ok, %{status_code: 202, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"batch_id" => batch_id, "file_count" => count}} ->
            Logger.info("X12Translator accepted batch #{batch_id} (#{count} files)")
            {:ok, %{batch_id: batch_id, file_count: count}}

          {:ok, decoded} ->
            {:ok, decoded}

          {:error, _} ->
            {:ok, %{raw: resp_body}}
        end

      {:ok, %{status_code: status, body: resp_body}} ->
        Logger.warning("X12Translator rejected submission — HTTP #{status}: #{resp_body}")
        {:error, "X12Translator returned HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("X12Translator connection failed: #{inspect(reason)}")
        {:error, "Cannot reach X12Translator: #{inspect(reason)}"}
    end
  end

  defp base_url do
    Application.get_env(:medicaid_claims_checker, :x12_translator_url, "http://localhost:4001")
  end
end
