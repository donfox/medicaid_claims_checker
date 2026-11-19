defmodule MedicaidClaimsChecker.Ingestion.ZipLimit do
  @moduledoc """
  Refuses a zip whose contents would unpack to more than a set size, before
  anything is unpacked. Zeros compress about 1000:1, so without this a zip
  inside the 10 MB upload limit could unpack to about 10 GB and exhaust the
  server's memory or disk.

  The sizes are the ones the zip's own directory declares. The limit is
  `config :medicaid_claims_checker, :remote_fetcher, max_unzipped_bytes:`
  (default 100 MB), for uploads and scheduled fetches alike.
  """

  @default_max_unzipped_bytes 100_000_000

  @doc "The largest total unpacked size allowed, in bytes."
  def max_unzipped_bytes do
    :medicaid_claims_checker
    |> Application.get_env(:remote_fetcher, [])
    |> Keyword.get(:max_unzipped_bytes, @default_max_unzipped_bytes)
  end

  @doc """
  `:ok` when the zip (its bytes) unpacks to at most `limit` bytes;
  `{:error, message}` when it would unpack to more, or can't be read.
  """
  def check(zip_data, limit \\ max_unzipped_bytes()) when is_binary(zip_data) do
    case :zip.list_dir(zip_data) do
      {:ok, entries} ->
        total =
          entries
          |> Enum.flat_map(fn
            {:zip_file, _name, info, _comment, _offset, _comp_size} -> [elem(info, 1)]
            _comment -> []
          end)
          |> Enum.sum()

        if total <= limit,
          do: :ok,
          else:
            {:error, "it would unpack to #{mb(total)} MB, more than the #{mb(limit)} MB allowed"}

      {:error, _reason} ->
        {:error, "it is not a readable zip file"}
    end
  end

  defp mb(bytes), do: Float.round(bytes / 1_000_000, 1)
end
