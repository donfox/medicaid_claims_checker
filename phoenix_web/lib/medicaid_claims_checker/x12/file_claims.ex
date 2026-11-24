defmodule MedicaidClaimsChecker.X12.FileClaims do
  @moduledoc """
  Turns one X12 or EDI file into the claims to ingest. Manual uploads and
  scheduled fetches both use it, so a file is read the same way however it
  arrives.

  A file can hold several transaction sets, and a transaction set several
  claims. Each claim is translated on its own and tagged with the file it
  came from (`source_file`), so ingest can refuse a file that was already
  submitted. A file or claim that can't be read becomes a problem instead,
  and the rest of the file is still used.
  """

  alias MedicaidClaimsChecker.Claims.Fingerprint
  alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}

  @doc """
  Returns `{claims, problems}` for one file.

  Each claim is `%{"filename", "claim", "source_file"}`: the claim's own
  name (`<file>.json`, or `<file>_<claim_id>.json` when the file holds
  several claims), the translated claim, and the file's name and SHA-256.
  Each problem is `%{"filename", "reason"}`, naming the file, or the file
  and claim ID, that couldn't be read.
  """
  @spec claims(String.t(), binary()) :: {[map()], [map()]}
  def claims(filename, content) do
    case ClaimSplitter.split_transaction_sets(content) do
      {:ok, transaction_sets} ->
        source = %{"filename" => filename, "sha256" => Fingerprint.file(content)}

        {claims, problems} =
          (transaction_sets || [content])
          |> Enum.map(&transaction_set_claims(filename, &1))
          |> combine()

        {Enum.map(claims, &Map.put(&1, "source_file", source)), problems}

      {:error, reason} ->
        {[], [problem(filename, reason)]}
    end
  end

  defp transaction_set_claims(filename, content) do
    case ClaimSplitter.split_claims_to_x12(content) do
      {:ok, nil} ->
        case translate(content) do
          {:ok, claim} -> {[claim_entry(Path.rootname(filename) <> ".json", claim)], []}
          {:error, reason} -> {[], [problem(filename, reason)]}
        end

      {:ok, split} when is_list(split) ->
        split
        |> Enum.map(fn %{claim_id: claim_id, x12_content: claim_x12} ->
          case translate(claim_x12) do
            {:ok, claim} ->
              {[claim_entry("#{Path.rootname(filename)}_#{claim_id}.json", claim)], []}

            {:error, reason} ->
              {[], [problem("#{filename} (claim #{claim_id})", reason)]}
          end
        end)
        |> combine()

      {:error, reason} ->
        {[], [problem(filename, reason)]}
    end
  end

  defp translate(x12_content) do
    with {:ok, flat_json} <- Converter.convert_content(x12_content) do
      SegmentMapper.map_from_json(flat_json)
    end
  end

  defp claim_entry(name, claim), do: %{"filename" => name, "claim" => claim}

  defp problem(filename, reason) do
    %{"filename" => filename, "reason" => if(is_binary(reason), do: reason, else: inspect(reason))}
  end

  defp combine(results) do
    Enum.reduce(results, {[], []}, fn {c, p}, {claims, problems} -> {claims ++ c, problems ++ p} end)
  end
end
