defmodule MedicaidClaimsChecker.Claims.JsonClaim do
  @moduledoc """
  Decides whether an uploaded JSON file is a claim.

  Each JSON upload must hold exactly one claim: an object with a top-level
  `claim_id`, or the X12 converter's output (an object with a `claim`
  object). Anything else is refused with a reason the uploader can act on,
  instead of being evaluated as an empty claim that every rule either
  rejects or cannot check.
  """

  alias MedicaidClaimsChecker.X12.SegmentMapper

  @doc """
  Parses an uploaded JSON file. Returns the normalized claim, or a reason
  the file is not a claim.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> check(decoded)
      {:error, _} -> {:error, "not valid JSON"}
    end
  end

  defp check(%{"claim_id" => _} = claim), do: {:ok, SegmentMapper.normalize(claim)}
  defp check(%{"claim" => %{}} = x12_json), do: {:ok, SegmentMapper.normalize(x12_json)}

  defp check(%{"rulesText" => _}),
    do: {:error, "an engine test request (rules and a list of claims), not a claim"}

  defp check(%{"claims" => _}),
    do: {:error, "holds a list of claims; upload one claim per file"}

  defp check(map) when is_map(map),
    do: {:error, "no claim found (expected a claim_id or claim field)"}

  defp check(list) when is_list(list),
    do: {:error, "holds a list, not a claim; upload one claim per file"}

  defp check(_), do: {:error, "not a claim"}
end
