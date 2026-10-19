defmodule MedicaidClaimsChecker.Claims.Fingerprint do
  @moduledoc """
  Hashes used to spot a submission that was already made.

    * `file/1` - SHA-256 of a submitted file's bytes. Catches an exact
      re-upload or re-fetch of the same file.
    * `claim/1` - SHA-256 of a translated claim, leaving out the X12
      envelope (interchange, functional group, submitter, receiver). Catches
      the same claim re-sent in a new envelope, where the control number and
      envelope date differ but the claim itself does not.

  A replacement (frequency code 7) or void (8) differs from the original in
  its frequency code, so it never matches the claim it corrects.
  """

  # Envelope data that changes when the same claims are re-transmitted.
  @envelope_keys ["interchange", "functional_group", "submitter", "receiver"]

  @doc "Lowercase hex SHA-256 of a file's raw bytes."
  def file(content) when is_binary(content), do: sha256(content)

  @doc "Lowercase hex SHA-256 of a claim, ignoring envelope keys and map key order."
  def claim(claim) when is_map(claim) do
    claim
    |> Map.drop(@envelope_keys)
    |> canonical()
    |> Jason.encode!()
    |> sha256()
  end

  # Maps become key-sorted [key, value] lists so the hash never depends on
  # map iteration order (which is unspecified for maps over 32 keys).
  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
