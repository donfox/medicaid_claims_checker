# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.SegmentMapper do
  @moduledoc """
  Maps flat all_segments JSON into semantic claim structure for 837 transactions.

  Takes the list of segment maps produced by `Converter.build_structure/2`
  (each with segment_id, elements, raw, line_number) and produces a
  hierarchical claim map suitable for POSTing to external systems.

  Supports 837P (Professional), 837I (Institutional), 837D (Dental).

  Operates on map-based segments (from decoded JSON or Converter output),
  NOT on Parser.Segment structs. Handles both atom and string keys.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Maps a list of segment maps into a semantic claim structure.

  ## Examples

      iex> {:ok, result} = SegmentMapper.map_segments(all_segments)
      iex> result.transaction_type
      "837P"
  """
  @spec map_segments(list(map())) :: {:ok, map()} | {:error, String.t()}
  def map_segments(segments) when is_list(segments) and length(segments) > 0 do
    transaction_type = detect_transaction_type(segments)

    result = %{
      transaction_type: transaction_type,
      interchange: extract_interchange(segments),
      functional_group: extract_functional_group(segments),
      submitter: extract_submitter(segments),
      receiver: extract_receiver(segments),
      billing_provider: extract_billing_provider(segments),
      claim: extract_claim(segments, transaction_type)
    }

    {:ok, normalize(result)}
  end

  def map_segments([]), do: {:error, "No segments provided"}
  def map_segments(_), do: {:error, "Expected a list of segment maps"}

  @doc """
  Convenience: decodes a JSON string containing all_segments and maps it.

  ## Examples

      iex> {:ok, result} = SegmentMapper.map_from_json(json_string)
  """
  @spec map_from_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  def map_from_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"all_segments" => segments}} when is_list(segments) ->
        map_segments(segments)

      {:ok, _} ->
        {:error, "JSON missing all_segments key"}

      {:error, reason} ->
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Segment access helpers
  # ---------------------------------------------------------------------------

  # Get element at position from a segment map. Handles atom/string keys.
  defp get_el(seg, pos) when is_map(seg) do
    elements = Map.get(seg, :elements) || Map.get(seg, "elements") || []
    Enum.at(elements, pos, "")
  end

  # Get segment_id from a segment map.
  defp seg_id(seg) when is_map(seg) do
    Map.get(seg, :segment_id) || Map.get(seg, "segment_id") || ""
  end

  # Find first segment with matching ID.
  defp find_seg(segments, id) do
    Enum.find(segments, fn seg -> seg_id(seg) == id end)
  end

  # Find all segments with matching ID.
  defp find_segs(segments, id) do
    Enum.filter(segments, fn seg -> seg_id(seg) == id end)
  end

  # Find first segment where segment_id matches and element at qual_pos matches qual_value.
  defp find_qualified(segments, id, qual_pos, qual_value) do
    Enum.find(segments, fn seg ->
      seg_id(seg) == id && get_el(seg, qual_pos) == qual_value
    end)
  end

  # Split composite element on ":" sub-element separator.
  defp split_composite(element) when is_binary(element) do
    String.split(element, ":", trim: false)
  end

  defp split_composite(_), do: []

  # Returns segments that appear after the first occurrence of `after_seg`
  # (a specific segment map) until hitting a segment whose ID is in `stop_ids`.
  defp segments_after(segments, after_seg, stop_ids) when is_list(stop_ids) do
    segments
    |> Enum.drop_while(fn seg -> seg != after_seg end)
    |> Enum.drop(1)
    |> Enum.take_while(fn seg -> seg_id(seg) not in stop_ids end)
  end

  # Returns segments from CLM up to (not including) the first LX or SE.
  defp claim_level_segments(segments) do
    clm = find_seg(segments, "CLM")
    if clm, do: [clm | segments_after(segments, clm, ["LX", "SE"])], else: []
  end

  # Partitions service-line segments into groups, each starting with LX.
  defp service_line_groups(segments) do
    # Find everything from first LX to SE
    first_lx_idx = Enum.find_index(segments, fn seg -> seg_id(seg) == "LX" end)
    se_idx = Enum.find_index(segments, fn seg -> seg_id(seg) == "SE" end)

    if first_lx_idx && se_idx do
      segments
      |> Enum.slice(first_lx_idx, se_idx - first_lx_idx)
      |> Enum.chunk_while(
        [],
        fn seg, acc ->
          if seg_id(seg) == "LX" && acc != [] do
            {:cont, Enum.reverse(acc), [seg]}
          else
            {:cont, [seg | acc]}
          end
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Transaction type detection
  # ---------------------------------------------------------------------------

  defp detect_transaction_type(segments) do
    gs = find_seg(segments, "GS")
    version = if gs, do: get_el(gs, 8), else: ""

    cond do
      String.contains?(version, "X098") or String.contains?(version, "X222") -> "837P"
      String.contains?(version, "X096") or String.contains?(version, "X223") -> "837I"
      String.contains?(version, "X097") or String.contains?(version, "X224") -> "837D"
      find_seg(segments, "SV1") != nil -> "837P"
      find_seg(segments, "SV2") != nil -> "837I"
      find_seg(segments, "SV3") != nil -> "837D"
      true -> "837"
    end
  end

  # ---------------------------------------------------------------------------
  # Section extractors
  # ---------------------------------------------------------------------------

  defp extract_interchange(segments) do
    case find_seg(segments, "ISA") do
      nil ->
        nil

      isa ->
        %{
          control_number: get_el(isa, 13) |> String.trim(),
          sender_id: get_el(isa, 6) |> String.trim(),
          receiver_id: get_el(isa, 8) |> String.trim(),
          date: get_el(isa, 9) |> String.trim(),
          time: get_el(isa, 10) |> String.trim(),
          version: get_el(isa, 12) |> String.trim(),
          usage_indicator: get_el(isa, 15) |> String.trim()
        }
    end
  end

  defp extract_functional_group(segments) do
    case find_seg(segments, "GS") do
      nil ->
        nil

      gs ->
        %{
          functional_id_code: get_el(gs, 1),
          sender_code: get_el(gs, 2),
          receiver_code: get_el(gs, 3),
          version: get_el(gs, 8)
        }
    end
  end

  defp extract_submitter(segments) do
    nm1 = find_qualified(segments, "NM1", 1, "41")
    per = find_qualified(segments, "PER", 1, "IC")

    if nm1 do
      %{
        name: get_el(nm1, 3),
        id: get_el(nm1, 9),
        contact_name: if(per, do: get_el(per, 2), else: nil),
        contact_phone: if(per, do: get_el(per, 4), else: nil)
      }
    else
      nil
    end
  end

  defp extract_receiver(segments) do
    case find_qualified(segments, "NM1", 1, "40") do
      nil -> nil
      nm1 -> %{name: get_el(nm1, 3), id: get_el(nm1, 9)}
    end
  end

  defp extract_billing_provider(segments) do
    nm1 = find_qualified(segments, "NM1", 1, "85")

    if nm1 do
      # Collect N3, N4, REF after NM1*85 until next HL or NM1
      trailing = segments_after(segments, nm1, ["HL", "NM1"])
      n3 = Enum.find(trailing, fn seg -> seg_id(seg) == "N3" end)
      n4 = Enum.find(trailing, fn seg -> seg_id(seg) == "N4" end)
      ref_ei = Enum.find(trailing, fn seg -> seg_id(seg) == "REF" && get_el(seg, 1) == "EI" end)

      # PRV*BI can appear before NM1*85, so search full segments
      prv = find_qualified(segments, "PRV", 1, "BI")

      %{
        name: get_el(nm1, 3),
        npi: get_el(nm1, 9),
        taxonomy_code: if(prv, do: get_el(prv, 3), else: nil),
        tax_id: if(ref_ei, do: get_el(ref_ei, 2), else: nil),
        address: extract_address(n3, n4)
      }
    else
      nil
    end
  end

  defp extract_address(n3, n4) do
    if n3 || n4 do
      %{
        street: if(n3, do: get_el(n3, 1), else: nil),
        city: if(n4, do: get_el(n4, 1), else: nil),
        state: if(n4, do: get_el(n4, 2), else: nil),
        zip: if(n4, do: get_el(n4, 3), else: nil)
      }
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Claim extraction (orchestrates sub-extractors)
  # ---------------------------------------------------------------------------

  defp extract_claim(segments, transaction_type) do
    clm = find_seg(segments, "CLM")

    if clm do
      # Parse CLM-05 composite: place_of_service:facility_type:frequency_code
      clm05_parts = split_composite(get_el(clm, 5))

      # Claim-level segments (between CLM and first LX)
      claim_segs = claim_level_segments(segments)

      %{
        claim_id: get_el(clm, 1),
        total_charge_amount: get_el(clm, 2),
        place_of_service: Enum.at(clm05_parts, 0, ""),
        facility_type: Enum.at(clm05_parts, 1, ""),
        frequency_code: Enum.at(clm05_parts, 2, ""),
        claim_filing_indicator: extract_claim_filing_indicator(segments),
        subscriber: extract_subscriber(segments),
        payer: extract_payer(segments),
        dates: extract_dates(claim_segs),
        diagnosis_codes: extract_diagnosis_codes(claim_segs),
        rendering_provider: extract_rendering_provider(claim_segs),
        attending_provider: extract_attending_provider(claim_segs),
        institutional_claim: extract_institutional_claim(claim_segs),
        service_lines: extract_service_lines(segments, transaction_type)
      }
    else
      nil
    end
  end

  defp extract_claim_filing_indicator(segments) do
    case find_seg(segments, "SBR") do
      nil -> nil
      sbr -> get_el(sbr, 9)
    end
  end

  defp extract_subscriber(segments) do
    nm1 = find_qualified(segments, "NM1", 1, "IL")
    sbr = find_seg(segments, "SBR")

    if nm1 do
      trailing = segments_after(segments, nm1, ["CLM", "NM1", "HL"])
      n3 = Enum.find(trailing, fn seg -> seg_id(seg) == "N3" end)
      n4 = Enum.find(trailing, fn seg -> seg_id(seg) == "N4" end)
      dmg = Enum.find(trailing, fn seg -> seg_id(seg) == "DMG" end)

      %{
        last_name: get_el(nm1, 3),
        first_name: get_el(nm1, 4),
        middle_name: get_el(nm1, 5),
        member_id: get_el(nm1, 9),
        payer_responsibility: if(sbr, do: get_el(sbr, 1), else: nil),
        relationship_code: if(sbr, do: get_el(sbr, 2), else: nil),
        group_number: if(sbr, do: get_el(sbr, 3), else: nil),
        address: extract_address(n3, n4),
        date_of_birth: if(dmg, do: get_el(dmg, 2), else: nil),
        gender: if(dmg, do: get_el(dmg, 3), else: nil)
      }
    else
      nil
    end
  end

  defp extract_payer(segments) do
    case find_qualified(segments, "NM1", 1, "PR") do
      nil ->
        nil

      nm1 ->
        %{
          name: get_el(nm1, 3),
          payer_id: get_el(nm1, 9)
        }
    end
  end

  defp extract_dates(claim_segs) do
    claim_segs
    |> find_segs("DTP")
    |> Enum.reduce(%{}, fn dtp, acc ->
      key = date_qualifier_to_key(get_el(dtp, 1))
      value = get_el(dtp, 3)
      Map.put(acc, key, value)
    end)
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  defp date_qualifier_to_key("431"), do: :onset_date
  defp date_qualifier_to_key("435"), do: :admission_date
  defp date_qualifier_to_key("096"), do: :discharge_date
  defp date_qualifier_to_key("472"), do: :service_date
  defp date_qualifier_to_key("439"), do: :accident_date
  defp date_qualifier_to_key(code), do: String.to_atom("date_#{code}")

  defp extract_diagnosis_codes(claim_segs) do
    claim_segs
    |> find_segs("HI")
    |> Enum.flat_map(fn hi ->
      elements = Map.get(hi, :elements) || Map.get(hi, "elements") || []

      # Skip element 0 (segment ID "HI"), each subsequent element is a composite
      elements
      |> Enum.drop(1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn composite ->
        parts = split_composite(composite)
        %{qualifier: Enum.at(parts, 0, ""), code: Enum.at(parts, 1, "")}
      end)
    end)
  end

  defp extract_rendering_provider(claim_segs) do
    nm1 = find_qualified(claim_segs, "NM1", 1, "82")

    if nm1 do
      prv = find_qualified(claim_segs, "PRV", 1, "PE")

      %{
        last_name: get_el(nm1, 3),
        first_name: get_el(nm1, 4),
        middle_name: get_el(nm1, 5),
        npi: get_el(nm1, 9),
        taxonomy_code: if(prv, do: get_el(prv, 3), else: nil)
      }
    else
      nil
    end
  end

  defp extract_attending_provider(claim_segs) do
    nm1 = find_qualified(claim_segs, "NM1", 1, "71")

    if nm1 do
      prv = find_qualified(claim_segs, "PRV", 1, "AT")

      %{
        last_name: get_el(nm1, 3),
        first_name: get_el(nm1, 4),
        middle_name: get_el(nm1, 5),
        npi: get_el(nm1, 9),
        taxonomy_code: if(prv, do: get_el(prv, 3), else: nil)
      }
    else
      nil
    end
  end

  defp extract_institutional_claim(claim_segs) do
    case find_seg(claim_segs, "CL1") do
      nil ->
        nil

      cl1 ->
        %{
          admission_type: get_el(cl1, 1),
          admission_source: get_el(cl1, 2),
          patient_status: get_el(cl1, 3)
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Service line extraction
  # ---------------------------------------------------------------------------

  defp extract_service_lines(segments, transaction_type) do
    segments
    |> service_line_groups()
    |> Enum.map(fn line_segs ->
      lx = find_seg(line_segs, "LX")
      dtp = find_qualified(line_segs, "DTP", 1, "472")

      base = %{
        line_number: if(lx, do: parse_int(get_el(lx, 1)), else: nil),
        service_date: if(dtp, do: get_el(dtp, 3), else: nil)
      }

      case transaction_type do
        "837P" -> Map.merge(base, extract_sv1_line(line_segs))
        "837I" -> Map.merge(base, extract_sv2_line(line_segs))
        "837D" -> Map.merge(base, extract_sv3_line(line_segs))
        _ -> Map.merge(base, extract_sv1_line(line_segs))
      end
    end)
  end

  defp extract_sv1_line(line_segs) do
    case find_seg(line_segs, "SV1") do
      nil ->
        %{
          procedure_qualifier: nil, procedure_code: nil,
          charge_amount: nil, unit_type: nil, units: nil,
          diagnosis_pointer: nil, revenue_code: nil, tooth_info: nil
        }

      sv1 ->
        proc_parts = split_composite(get_el(sv1, 1))

        %{
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          charge_amount: get_el(sv1, 2),
          unit_type: get_el(sv1, 3),
          units: get_el(sv1, 4),
          diagnosis_pointer: get_el(sv1, 7),
          revenue_code: nil,
          tooth_info: nil
        }
    end
  end

  defp extract_sv2_line(line_segs) do
    case find_seg(line_segs, "SV2") do
      nil ->
        %{
          procedure_qualifier: nil, procedure_code: nil,
          charge_amount: nil, unit_type: nil, units: nil,
          diagnosis_pointer: nil, revenue_code: nil, tooth_info: nil
        }

      sv2 ->
        proc_parts = split_composite(get_el(sv2, 2))

        %{
          revenue_code: get_el(sv2, 1),
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          charge_amount: get_el(sv2, 3),
          unit_type: get_el(sv2, 4),
          units: get_el(sv2, 5),
          diagnosis_pointer: nil,
          tooth_info: nil
        }
    end
  end

  defp extract_sv3_line(line_segs) do
    case find_seg(line_segs, "SV3") do
      nil ->
        %{
          procedure_qualifier: nil, procedure_code: nil,
          charge_amount: nil, unit_type: nil, units: nil,
          diagnosis_pointer: nil, revenue_code: nil, tooth_info: nil
        }

      sv3 ->
        proc_parts = split_composite(get_el(sv3, 1))

        %{
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          charge_amount: get_el(sv3, 2),
          unit_type: nil,
          units: get_el(sv3, 5),
          diagnosis_pointer: nil,
          revenue_code: nil,
          tooth_info: extract_tooth_info(line_segs)
        }
    end
  end

  defp extract_tooth_info(line_segs) do
    case find_seg(line_segs, "TOO") do
      nil ->
        nil

      too ->
        # Element 2 may be a composite like "19:MO" (tooth_number:surface)
        tooth_parts = split_composite(get_el(too, 2))

        %{
          tooth_code_qualifier: get_el(too, 1),
          tooth_number: Enum.at(tooth_parts, 0, ""),
          tooth_surface:
            case Enum.at(tooth_parts, 1) do
              nil -> get_el(too, 3)
              "" -> get_el(too, 3)
              surface -> surface
            end
        }
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Business-schema normalization
  # ---------------------------------------------------------------------------

  @doc """
  Maps X12Translator output to the flat business schema expected by the rules engine.

  Claims already in business schema (top-level `claim_id` key) pass through unchanged,
  making this function idempotent.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"claim_id" => _} = claim), do: claim
  def normalize(%{claim_id: _} = claim), do: claim

  def normalize(x12_map) when is_map(x12_map) do
    claim = nf(x12_map, "claim") || %{}
    billing = nf(x12_map, "billing_provider") || %{}
    subscriber = nf(claim, "subscriber") || %{}
    total_charge_raw = nf(claim, "total_charge_amount")
    total_charge = parse_money(total_charge_raw)

    service_lines =
      (nf(claim, "service_lines") || [])
      |> Enum.map(&normalize_service_line/1)

    %{
      "claim_id" => nf(claim, "claim_id"),
      "transaction_type" => nf(x12_map, "transaction_type"),
      "provider" => %{
        "npi" => nf(billing, "npi"),
        "name" => nf(billing, "name"),
        "taxonomy" => nf(billing, "taxonomy_code"),
        "tax_id" => nf(billing, "tax_id"),
        "tenure_days" => nil
      },
      "patient" => %{
        "date_of_birth" => nf(subscriber, "date_of_birth"),
        "gender" => nf(subscriber, "gender"),
        "name" => %{
          "first" => nf(subscriber, "first_name"),
          "last" => nf(subscriber, "last_name"),
          "middle" => nf(subscriber, "middle_name")
        }
      },
      "financial" => %{
        "claim_amount" => total_charge
      },
      "diagnosis_codes" => nf(claim, "diagnosis_codes") || [],
      "service_lines" => service_lines,
      "claim_totals" => %{
        "total_charges" => total_charge
      },
      "billing_provider" => %{
        "npi" => nf(billing, "npi"),
        "name" => nf(billing, "name"),
        "taxonomy" => nf(billing, "taxonomy_code"),
        "tax_id" => nf(billing, "tax_id"),
        "address" => nf(billing, "address")
      },
      "authorization" => %{
        "authorization_number" => nil
      },
      "interchange" => nf(x12_map, "interchange"),
      "functional_group" => nf(x12_map, "functional_group"),
      "submitter" => nf(x12_map, "submitter"),
      "receiver" => nf(x12_map, "receiver"),
      "subscriber" => subscriber,
      "payer" => nf(claim, "payer"),
      "rendering_provider" => nf(claim, "rendering_provider")
    }
  end

  def normalize(other), do: other

  defp normalize_service_line(line) when is_map(line) do
    # date_of_service may already be renamed, or still be service_date (X12 schema)
    date = nf(line, "service_date") || nf(line, "date_of_service")

    %{
      "line_number" => nf(line, "line_number"),
      "date_of_service" => date,
      "procedure_code" => nf(line, "procedure_code"),
      "procedure_qualifier" => nf(line, "procedure_qualifier"),
      "charge_amount" => nf(line, "charge_amount"),
      "unit_type" => nf(line, "unit_type"),
      "units" => nf(line, "units"),
      "diagnosis_pointer" => nf(line, "diagnosis_pointer"),
      "revenue_code" => nf(line, "revenue_code"),
      "tooth_info" => nf(line, "tooth_info")
    }
  end

  defp normalize_service_line(other), do: other

  # Access a field by string key, falling back to atom key.
  defp nf(map, str_key) when is_map(map) do
    case Map.fetch(map, str_key) do
      {:ok, v} ->
        v

      :error ->
        try do
          Map.get(map, String.to_existing_atom(str_key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp nf(_, _), do: nil

  defp parse_money(nil), do: nil
  defp parse_money(v) when is_float(v), do: v
  defp parse_money(v) when is_integer(v), do: v * 1.0

  defp parse_money(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
end
