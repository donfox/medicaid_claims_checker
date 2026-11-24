# Copyright (c) 2026 Don Fox
# Licensed under the MIT License. See LICENSE file in the project root.

defmodule MedicaidClaimsChecker.X12.SegmentMapper do
  @moduledoc """
  Maps one claim's flat segment list into the claim layout rules read.

  `map_from_json/1` takes the JSON from `Converter.convert_content/1` (each
  segment with segment_id, elements, raw, line_number), `map_segments/2`
  builds an X12-shaped map, and `normalize/1` flattens that into the claim
  contract listed in `Claims.RuleSchemaValidator`.

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

  Options:
    * `:sub_element_separator` - the composite separator from ISA16 (default `":"`)
  """
  @spec map_segments(list(map()), keyword()) :: {:ok, map()} | {:error, String.t()}
  def map_segments(segments, opts \\ [])

  def map_segments(segments, opts) when is_list(segments) and length(segments) > 0 do
    transaction_type = detect_transaction_type(segments)
    sub = Keyword.get(opts, :sub_element_separator) || ":"

    result = %{
      transaction_type: transaction_type,
      interchange: extract_interchange(segments),
      functional_group: extract_functional_group(segments),
      submitter: extract_submitter(segments),
      receiver: extract_receiver(segments),
      billing_provider: extract_billing_provider(segments),
      claim: extract_claim(segments, transaction_type, sub)
    }

    {:ok, normalize(result)}
  end

  def map_segments([], _opts), do: {:error, "No segments provided"}
  def map_segments(_, _opts), do: {:error, "Expected a list of segment maps"}

  @doc """
  Convenience: decodes a JSON string containing all_segments and maps it.

  ## Examples

      iex> {:ok, result} = SegmentMapper.map_from_json(json_string)
  """
  @spec map_from_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  def map_from_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"all_segments" => segments} = doc} when is_list(segments) ->
        map_segments(segments, sub_element_separator: doc["sub_element_separator"])

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

  # Split a composite element on the file's sub-element separator (ISA16).
  defp split_composite(element, sub) when is_binary(element) do
    String.split(element, sub, trim: false)
  end

  defp split_composite(_, _sub), do: []

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

  defp extract_claim(segments, transaction_type, sub) do
    clm = find_seg(segments, "CLM")

    if clm do
      clm05 = clm05_fields(split_composite(get_el(clm, 5), sub), transaction_type)

      # Claim-level segments (between CLM and first LX)
      claim_segs = claim_level_segments(segments)
      prior_auth = find_qualified(claim_segs, "REF", 1, "G1")
      dates = extract_dates(claim_segs)

      %{
        claim_id: get_el(clm, 1),
        total_charge_amount: get_el(clm, 2),
        place_of_service: clm05.place_of_service,
        facility_type_code: clm05.facility_type_code,
        facility_code_qualifier: clm05.facility_code_qualifier,
        frequency_code: clm05.frequency_code,
        prior_authorization: if(prior_auth, do: get_el(prior_auth, 2), else: nil),
        subscriber: extract_subscriber(segments),
        patient: extract_patient(segments),
        payer: extract_payer(segments),
        dates: dates,
        diagnosis_codes: extract_diagnosis_codes(claim_segs, sub),
        other_codes: extract_other_codes(claim_segs, sub),
        rendering_provider: extract_rendering_provider(claim_segs),
        service_lines: extract_service_lines(segments, transaction_type, sub, dates)
      }
    else
      nil
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

  # The patient loop (HL 23, NM1*QC) is only sent when the patient is not
  # the subscriber, a dependant for example. Without it the patient is the
  # subscriber, and `normalize/1` uses the subscriber's details.
  defp extract_patient(segments) do
    case find_qualified(segments, "NM1", 1, "QC") do
      nil ->
        nil

      nm1 ->
        trailing = segments_after(segments, nm1, ["CLM", "NM1", "HL"])
        dmg = Enum.find(trailing, fn seg -> seg_id(seg) == "DMG" end)

        %{
          last_name: get_el(nm1, 3),
          first_name: get_el(nm1, 4),
          middle_name: get_el(nm1, 5),
          date_of_birth: if(dmg, do: get_el(dmg, 2), else: nil),
          gender: if(dmg, do: get_el(dmg, 3), else: nil)
        }
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

  # Claim-level dates. The statement period (DTP*434, 837I) is where an
  # institutional claim carries its dates; a service line without its own
  # DTP*472 falls under it. Admission (DTP*435) is D8 on 837P and DT
  # (date and time) on 837I; only the date is kept.
  defp extract_dates(claim_segs) do
    {statement_from, statement_to} =
      case find_qualified(claim_segs, "DTP", 1, "434") do
        nil -> {nil, nil}
        dtp -> date_period(dtp)
      end

    admission =
      case find_qualified(claim_segs, "DTP", 1, "435") do
        nil -> nil
        dtp -> dtp |> get_el(3) |> String.slice(0, 8)
      end

    %{statement_from: statement_from, statement_to: statement_to, admission_date: admission}
  end

  # A DTP date as {from, to}: D8 is one date (to is nil), RD8 a range
  # written CCYYMMDD-CCYYMMDD. A one-day range has no separate end.
  defp date_period(dtp) do
    value = get_el(dtp, 3)

    case {get_el(dtp, 2), String.split(value, "-", parts: 2)} do
      {"RD8", [from, to]} when from == to -> {from, nil}
      {"RD8", [from, to]} -> {from, to}
      _ -> {value, nil}
    end
  end

  # HI qualifiers that carry a diagnosis: principal, admitting, other,
  # external cause and patient's reason for visit, ICD-10 (AB*/APR) and the
  # retired ICD-9 forms (B*/PR). Everything else an HI segment can hold on
  # an 837I (condition BG, occurrence BH/BI, value BE, procedure BBR/BBQ/BR/BQ,
  # DRG DR, treatment TC) goes to `other_codes`, so it isn't counted as a
  # diagnosis.
  @diagnosis_qualifiers ~w(ABK ABJ ABF ABN APR BK BJ BF BN PR)

  defp extract_diagnosis_codes(claim_segs, sub) do
    Enum.filter(extract_hi_codes(claim_segs, sub), &(&1.qualifier in @diagnosis_qualifiers))
  end

  defp extract_other_codes(claim_segs, sub) do
    Enum.reject(extract_hi_codes(claim_segs, sub), &(&1.qualifier in @diagnosis_qualifiers))
  end

  defp extract_hi_codes(claim_segs, sub) do
    claim_segs
    |> find_segs("HI")
    |> Enum.flat_map(fn hi ->
      elements = Map.get(hi, :elements) || Map.get(hi, "elements") || []

      # Skip element 0 (segment ID "HI"), each subsequent element is a composite
      elements
      |> Enum.drop(1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn composite ->
        parts = split_composite(composite, sub)
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

  # CLM05 is a composite whose first part depends on the claim type. On 837P
  # and 837D it is the place of service (qualifier "B"); on 837I it is the
  # facility type code, the first two digits of the type of bill (qualifier
  # "A"), and an institutional claim has no place of service. The two code
  # sets overlap (facility type 11 is hospital inpatient, place of service 11
  # is an office), so an 837I code must never reach place_of_service.
  defp clm05_fields(parts, transaction_type) do
    first = Enum.at(parts, 0, "")

    {pos, facility_type} =
      if transaction_type == "837I", do: {"", first}, else: {first, ""}

    %{
      place_of_service: pos,
      facility_type_code: facility_type,
      facility_code_qualifier: Enum.at(parts, 1, ""),
      frequency_code: Enum.at(parts, 2, "")
    }
  end

  # ---------------------------------------------------------------------------
  # Service line extraction
  # ---------------------------------------------------------------------------

  defp extract_service_lines(segments, transaction_type, sub, claim_dates) do
    segments
    |> service_line_groups()
    |> Enum.map(fn line_segs ->
      lx = find_seg(line_segs, "LX")

      # A line without its own date takes the claim's statement period.
      {from, to} =
        case find_qualified(line_segs, "DTP", 1, "472") do
          nil -> {claim_dates.statement_from, claim_dates.statement_to}
          dtp -> date_period(dtp)
        end

      base = %{
        line_number: if(lx, do: parse_int(get_el(lx, 1)), else: nil),
        service_date: from,
        service_date_end: to
      }

      case transaction_type do
        "837P" -> Map.merge(base, extract_sv1_line(line_segs, sub))
        "837I" -> Map.merge(base, extract_sv2_line(line_segs, sub))
        "837D" -> Map.merge(base, extract_sv3_line(line_segs, sub))
        _ -> Map.merge(base, extract_sv1_line(line_segs, sub))
      end
    end)
  end

  defp extract_sv1_line(line_segs, sub) do
    case find_seg(line_segs, "SV1") do
      nil ->
        %{
          procedure_qualifier: nil,
          procedure_code: nil,
          charge_amount: nil,
          unit_type: nil,
          units: nil,
          diagnosis_pointer: nil,
          revenue_code: nil,
          tooth_info: nil
        }

      sv1 ->
        proc_parts = split_composite(get_el(sv1, 1), sub)

        %{
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          modifiers: procedure_modifiers(proc_parts),
          charge_amount: get_el(sv1, 2),
          unit_type: get_el(sv1, 3),
          units: get_el(sv1, 4),
          # SV1-05 overrides the claim's place of service for this line
          place_of_service: get_el(sv1, 5),
          diagnosis_pointer: get_el(sv1, 7),
          revenue_code: nil,
          tooth_info: nil
        }
    end
  end

  defp extract_sv2_line(line_segs, sub) do
    case find_seg(line_segs, "SV2") do
      nil ->
        %{
          procedure_qualifier: nil,
          procedure_code: nil,
          charge_amount: nil,
          unit_type: nil,
          units: nil,
          diagnosis_pointer: nil,
          revenue_code: nil,
          tooth_info: nil
        }

      sv2 ->
        proc_parts = split_composite(get_el(sv2, 2), sub)

        %{
          revenue_code: get_el(sv2, 1),
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          modifiers: procedure_modifiers(proc_parts),
          charge_amount: get_el(sv2, 3),
          unit_type: get_el(sv2, 4),
          units: get_el(sv2, 5),
          diagnosis_pointer: nil,
          tooth_info: nil
        }
    end
  end

  defp extract_sv3_line(line_segs, sub) do
    case find_seg(line_segs, "SV3") do
      nil ->
        %{
          procedure_qualifier: nil,
          procedure_code: nil,
          charge_amount: nil,
          unit_type: nil,
          units: nil,
          diagnosis_pointer: nil,
          revenue_code: nil,
          tooth_info: nil
        }

      sv3 ->
        proc_parts = split_composite(get_el(sv3, 1), sub)

        %{
          procedure_qualifier: Enum.at(proc_parts, 0, ""),
          procedure_code: Enum.at(proc_parts, 1, ""),
          modifiers: procedure_modifiers(proc_parts),
          charge_amount: get_el(sv3, 2),
          unit_type: nil,
          # SV3-06 is the procedure count; SV3-05 is the prosthesis code
          units: get_el(sv3, 6),
          diagnosis_pointer: nil,
          revenue_code: nil,
          tooth_info: extract_tooth_info(line_segs, sub)
        }
    end
  end

  # The procedure composite is qualifier:code:modifier1:...:modifier4:description.
  defp procedure_modifiers(proc_parts) do
    proc_parts
    |> Enum.slice(2, 4)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&%{code: &1})
  end

  defp extract_tooth_info(line_segs, sub) do
    case find_seg(line_segs, "TOO") do
      nil ->
        nil

      too ->
        # Element 2 may be a composite like "19:MO" (tooth_number:surface)
        tooth_parts = split_composite(get_el(too, 2), sub)

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
  Flattens the map from `map_segments/2` (or an uploaded JSON claim in that
  X12 shape) into the claim contract rules read.

  Claims already in that contract (top-level `claim_id` key) pass through
  unchanged, except that procedure modifiers given as plain codes become
  `%{"code" => code}`, the form rules read. This function is idempotent.
  Absent X12 elements arrive as "", which a rule would treat as present, so
  blank values become nil.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"claim_id" => _} = claim), do: json_claim_modifiers(claim)
  def normalize(%{claim_id: _} = claim), do: claim

  def normalize(x12_map) when is_map(x12_map) do
    claim = nf(x12_map, "claim") || %{}
    billing = nf(x12_map, "billing_provider") || %{}
    subscriber = nf(claim, "subscriber") || %{}
    patient = nf(claim, "patient") || subscriber
    dates = nf(claim, "dates") || %{}
    total_charge_raw = nf(claim, "total_charge_amount")
    total_charge = parse_money(total_charge_raw)
    place_of_service = blank_to_nil(nf(claim, "place_of_service"))

    service_lines =
      (nf(claim, "service_lines") || [])
      |> Enum.map(&normalize_service_line(&1, place_of_service))

    # X12 elements that are absent come through as "", which rules would
    # treat as present; identifiers and codes become nil instead.
    billing_npi = blank_to_nil(nf(billing, "npi"))
    billing_taxonomy = blank_to_nil(nf(billing, "taxonomy_code"))
    billing_tax_id = blank_to_nil(nf(billing, "tax_id"))

    %{
      "claim_id" => blank_to_nil(nf(claim, "claim_id")),
      "transaction_type" => nf(x12_map, "transaction_type"),
      "provider" => %{
        "npi" => billing_npi,
        "name" => nf(billing, "name"),
        "taxonomy" => billing_taxonomy,
        "tax_id" => billing_tax_id,
        "tenure_days" => nil
      },
      "claim_details" => %{
        "place_of_service" => place_of_service,
        # 837I only: CLM05-1, the facility type code (11 hospital inpatient,
        # 13 hospital outpatient, 21 skilled nursing, ...).
        "facility_type_code" => blank_to_nil(nf(claim, "facility_type_code")),
        # CLM05-3: 1 original, 7 replacement, 8 void. Also keeps a void or
        # replacement from matching the original as a duplicate submission.
        "frequency_code" => blank_to_nil(nf(claim, "frequency_code")),
        # DTP*434 statement period and DTP*435 admission date (837I).
        "statement_from_date" => blank_to_nil(nf(dates, "statement_from")),
        "statement_to_date" => blank_to_nil(nf(dates, "statement_to")),
        "admission_date" => blank_to_nil(nf(dates, "admission_date"))
      },
      "patient" => %{
        "date_of_birth" => blank_to_nil(nf(patient, "date_of_birth")),
        "gender" => blank_to_nil(nf(patient, "gender")),
        "name" => %{
          "first" => blank_to_nil(nf(patient, "first_name")),
          "last" => blank_to_nil(nf(patient, "last_name")),
          "middle" => blank_to_nil(nf(patient, "middle_name"))
        }
      },
      "financial" => %{
        "claim_amount" => total_charge
      },
      "diagnosis_codes" => nf(claim, "diagnosis_codes") || [],
      # The non-diagnosis HI codes (837I condition, occurrence, value and
      # procedure codes), each with its qualifier.
      "other_codes" => nf(claim, "other_codes") || [],
      "service_lines" => service_lines,
      "claim_totals" => %{
        "total_charges" => total_charge
      },
      "billing_provider" => %{
        "npi" => billing_npi,
        "name" => nf(billing, "name"),
        "taxonomy" => billing_taxonomy,
        "tax_id" => billing_tax_id,
        "address" => nf(billing, "address")
      },
      "authorization" => %{
        "authorization_number" => blank_to_nil(nf(claim, "prior_authorization"))
      },
      "interchange" => nf(x12_map, "interchange"),
      "functional_group" => nf(x12_map, "functional_group"),
      "submitter" => nf(x12_map, "submitter"),
      "receiver" => nf(x12_map, "receiver"),
      "subscriber" => subscriber,
      "payer" => nf(claim, "payer"),
      "rendering_provider" => nf(claim, "rendering_provider")
    }
    |> blank_values_to_nil()
  end

  def normalize(other), do: other

  defp json_claim_modifiers(%{"service_lines" => lines} = claim) when is_list(lines),
    do: %{claim | "service_lines" => Enum.map(lines, &json_line_modifiers/1)}

  defp json_claim_modifiers(claim), do: claim

  defp json_line_modifiers(%{"modifiers" => modifiers} = line) when not is_nil(modifiers),
    do: %{line | "modifiers" => modifiers |> List.wrap() |> Enum.flat_map(&json_modifier/1)}

  defp json_line_modifiers(line), do: line

  defp json_modifier(%{"code" => _} = modifier), do: [modifier]
  defp json_modifier(code) when is_integer(code), do: [%{"code" => Integer.to_string(code)}]

  defp json_modifier(code) when is_binary(code) do
    case String.trim(code) do
      "" -> []
      trimmed -> [%{"code" => trimmed}]
    end
  end

  defp json_modifier(_other), do: []

  defp normalize_service_line(line, claim_place_of_service) when is_map(line) do
    # date_of_service may already be renamed, or still be service_date (X12 schema)
    date = nf(line, "service_date") || nf(line, "date_of_service")
    date_end = nf(line, "service_date_end") || nf(line, "date_of_service_end")

    %{
      "place_of_service" => blank_to_nil(nf(line, "place_of_service")) || claim_place_of_service,
      "line_number" => nf(line, "line_number"),
      "date_of_service" => blank_to_nil(date),
      "date_of_service_end" => blank_to_nil(date_end),
      "procedure_code" => blank_to_nil(nf(line, "procedure_code")),
      "procedure_qualifier" => blank_to_nil(nf(line, "procedure_qualifier")),
      "modifiers" => Enum.map(nf(line, "modifiers") || [], &%{"code" => nf(&1, "code")}),
      "charge_amount" => blank_to_nil(nf(line, "charge_amount")),
      "unit_type" => blank_to_nil(nf(line, "unit_type")),
      "units" => blank_to_nil(nf(line, "units")),
      "diagnosis_pointer" => blank_to_nil(nf(line, "diagnosis_pointer")),
      "revenue_code" => blank_to_nil(nf(line, "revenue_code")),
      "tooth_info" => nf(line, "tooth_info")
    }
  end

  defp normalize_service_line(other, _claim_place_of_service), do: other

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  # Applies blank_to_nil to every value in the claim, keys left as they are.
  defp blank_values_to_nil(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, blank_values_to_nil(v)} end)

  defp blank_values_to_nil(list) when is_list(list), do: Enum.map(list, &blank_values_to_nil/1)
  defp blank_values_to_nil(value), do: blank_to_nil(value)

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
