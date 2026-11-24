defmodule MedicaidClaimsChecker.Claims.Fingerprint do
  @moduledoc """
  Hashes used to spot a submission that was already made.

    * `file/1` - SHA-256 of a submitted file's bytes. Catches an exact
      re-upload or re-fetch of the same file.
    * `claim/1` - SHA-256 of the fields that identify a claim. Catches the
      same claim re-sent in a new envelope, where the control number and
      envelope date differ but the claim itself does not.

  The claim hash reads a fixed list of fields and ignores blanks, so a
  translator update that adds a field or stores a blank differently doesn't
  make a known claim look new. Changing the list changes every hash: a
  migration must then recalculate `edi_files.claim_fingerprint`.

  A replacement (frequency code 7) or void (8) differs from the original in
  its frequency code, so it never matches the claim it corrects.
  """

  # Envelope data that changes when the same claims are re-transmitted.
  @envelope_keys ["interchange", "functional_group", "submitter", "receiver"]

  @detail_fields ~w(frequency_code facility_type_code place_of_service
                    statement_from_date statement_to_date admission_date discharge_date)

  @line_fields ~w(procedure_qualifier procedure_code revenue_code unit_type
                  date_of_service date_of_service_end place_of_service)

  @tooth_fields ~w(tooth_code_qualifier tooth_number tooth_surface)

  @doc "Lowercase hex SHA-256 of a file's raw bytes."
  def file(content) when is_binary(content), do: sha256(content)

  @doc "Lowercase hex SHA-256 of the fields that identify a claim."
  def claim(claim) when is_map(claim) do
    claim
    |> identity()
    |> canonical()
    |> Jason.encode!()
    |> sha256()
  end

  # Without a claim ID the fixed fields may not tell two claims apart, so
  # everything outside the envelope is hashed.
  defp identity(claim) do
    case canonical(claim["claim_id"]) do
      nil -> Map.drop(claim, @envelope_keys)
      claim_id -> identity(claim, claim_id)
    end
  end

  defp identity(claim, claim_id) do
    %{
      "claim_id" => claim_id,
      "transaction_type" => claim["transaction_type"],
      "details" => take(claim["claim_details"], @detail_fields),
      "billing_npi" => first(claim, [["billing_provider", "npi"], ["provider", "npi"]]),
      "rendering_npi" => at(claim, ["rendering_provider", "npi"]),
      "member_id" => first(claim, [["subscriber", "member_id"], ["patient", "patient_id"]]),
      "date_of_birth" =>
        first(claim, [["patient", "date_of_birth"], ["subscriber", "date_of_birth"]]),
      "amount" =>
        claim |> first([["financial", "claim_amount"], ["claim_totals", "total_charges"]]) |> number(),
      "authorization" => at(claim, ["authorization", "authorization_number"]),
      "diagnoses" => rows(claim["diagnosis_codes"], ~w(code qualifier)),
      "other_codes" => rows(claim["other_codes"], ~w(code qualifier)),
      "procedures" => rows(claim["procedure_codes"], ~w(code date_performed)),
      "lines" => claim["service_lines"] |> list() |> Enum.map(&line/1)
    }
  end

  defp line(line) when is_map(line) do
    line
    |> take(@line_fields)
    |> Map.merge(%{
      "line_number" => first(line, [["line_number"], ["service_line_number"]]),
      "charge" => line |> first([["charge_amount"], ["line_amount"]]) |> number(),
      "units" => number(line["units"]),
      "modifiers" => rows(line["modifiers"], ~w(code)),
      "pointers" =>
        line |> first([["diagnosis_pointer"], ["diagnosis_pointers"]]) |> List.wrap(),
      "tooth" => take(line["tooth_info"], @tooth_fields)
    })
  end

  defp line(other), do: other

  defp rows(value, fields) do
    value
    |> list()
    |> Enum.map(fn
      row when is_map(row) -> take(row, fields)
      other -> other
    end)
  end

  defp take(map, fields) when is_map(map), do: Map.take(map, fields)
  defp take(_other, _fields), do: %{}

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp first(map, paths) do
    Enum.find_value(paths, fn path -> map |> at(path) |> canonical() end)
  end

  defp at(value, []), do: value
  defp at(map, [key | rest]) when is_map(map), do: at(Map.get(map, key), rest)
  defp at(_other, _path), do: nil

  # 900, 900.0 and "900.00" are the same amount.
  defp number(value) when is_integer(value), do: value |> Decimal.new() |> decimal_text()
  defp number(value) when is_float(value), do: value |> Decimal.from_float() |> decimal_text()

  defp number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Decimal.parse(trimmed) do
      {decimal, ""} -> decimal_text(decimal)
      _ -> trimmed
    end
  end

  defp number(other), do: other

  defp decimal_text(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  # Maps become key-sorted [key, value] lists so the hash never depends on
  # map iteration order (which is unspecified for maps over 32 keys). Blank
  # values are left out, so nil, "", [] and a missing key all hash the same.
  defp canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> [to_string(key), canonical(value)] end)
      |> Enum.reject(fn [_key, value] -> is_nil(value) end)
      |> Enum.sort()

    if entries == [], do: nil, else: entries
  end

  defp canonical(list) when is_list(list) do
    case list |> Enum.map(&canonical/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> values
    end
  end

  defp canonical(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp canonical(other), do: other

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
