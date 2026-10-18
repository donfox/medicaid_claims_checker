defmodule MedicaidClaimsChecker.Claims.JsonClaim do
  @moduledoc """
  Reads the claims in an uploaded JSON file.

  A JSON upload holds one or more claims:

    * a single claim: an object with a top-level `claim_id`, or the X12
      converter's output (an object with a `claim` object);
    * a list of such claims, either bare (`[...]`) or wrapped
      (`{"claims": [...]}`).

  A file with no claim is refused with a reason the uploader can act on,
  instead of being evaluated as an empty claim that every rule either
  rejects or cannot check. In a list, each entry is checked on its own: good
  entries are kept and bad ones are reported by position.
  """

  alias MedicaidClaimsChecker.X12.SegmentMapper

  @doc """
  Parses an uploaded JSON file.

  Returns `{:ok, claims, refused}`, where `claims` are the normalized claims
  in file order and `refused` lists `{position, reason}` for list entries
  that are not claims (positions count from 1). Returns `{:error, reason}`
  when the file as a whole holds no claims.
  """
  @spec parse(binary()) ::
          {:ok, [map()], [{pos_integer(), String.t()}]} | {:error, String.t()}
  def parse(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> check_file(decoded)
      {:error, _} -> {:error, "not valid JSON"}
    end
  end

  defp check_file(%{"rulesText" => _}),
    do: {:error, "an engine test request (rules and a list of claims), not a claims file"}

  defp check_file(%{"claims" => list}) when is_list(list), do: check_list(list)
  defp check_file(%{"claims" => _}), do: {:error, "\"claims\" must be a list of claims"}
  defp check_file(list) when is_list(list), do: check_list(list)

  defp check_file(single) do
    case check_claim(single) do
      {:ok, claim} -> {:ok, [claim], []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_list([]), do: {:error, "the list of claims is empty"}

  defp check_list(list) do
    {claims, refused} =
      list
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {entry, position}, {claims, refused} ->
        case check_claim(entry) do
          {:ok, claim} -> {[claim | claims], refused}
          {:error, reason} -> {claims, [{position, reason} | refused]}
        end
      end)

    case claims do
      [] -> {:error, "none of the #{length(list)} entries is a claim"}
      _ -> {:ok, Enum.reverse(claims), Enum.reverse(refused)}
    end
  end

  defp check_claim(%{"claim_id" => _} = claim), do: {:ok, SegmentMapper.normalize(claim)}
  defp check_claim(%{"claim" => %{}} = x12_json), do: {:ok, SegmentMapper.normalize(x12_json)}

  defp check_claim(map) when is_map(map),
    do: {:error, "no claim found (expected a claim_id or claim field)"}

  defp check_claim(_), do: {:error, "not a claim"}
end
