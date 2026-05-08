defmodule MedicaidClaimsChecker.X12.Verifier do
  @moduledoc """
  Lightweight X12 file verification without full translation.

  This module performs pre-flight checks to validate X12 structure,
  count claims for billing estimation, and catch errors before translation.

  Verification is FREE and FAST (~5-20ms per file).
  """

  @doc """
  Verifies an X12 file structure and counts claims.

  Returns a verification result map with:
  - `valid?` - boolean indicating if verification passed
  - `claim_count` - number of billable claims found
  - `errors` - list of error messages (if any)
  - `warnings` - list of warning messages (non-fatal issues)
  - Additional metadata about the file structure

  ## Examples

      iex> verify("ISA*00*...*~\\nGS*HC*...~\\nST*837*0001~\\nCLM*...~\\n")
      %{valid?: true, claim_count: 1, errors: [], warnings: []}

      iex> verify("INVALID CONTENT")
      %{valid?: false, claim_count: 0, errors: ["Missing ISA segment"], warnings: []}
  """
  def verify(x12_content) when is_binary(x12_content) do
    x12_content
    |> String.trim()
    |> run_verification_checks()
  end

  defp run_verification_checks("") do
    %{
      valid?: false,
      claim_count: 0,
      errors: ["File is empty or contains only whitespace"],
      warnings: [],
      checked_at: DateTime.utc_now()
    }
  end

  defp run_verification_checks(content) do
    # Step 1: Detect delimiters
    {segment_delimiter, element_delimiter} = detect_delimiters(content)

    # Step 2: Parse segments
    segments = parse_segments(content, segment_delimiter, element_delimiter)

    # Step 3: Run validation checks
    errors = []
    warnings = []

    # Check envelope structure
    {envelope_errors, envelope_warnings} = validate_envelope(segments)
    errors = errors ++ envelope_errors
    warnings = warnings ++ envelope_warnings

    # Check required segments for 837
    {required_errors, required_warnings} = validate_required_segments(segments)
    errors = errors ++ required_errors
    warnings = warnings ++ required_warnings

    # Check segment syntax
    {syntax_errors, syntax_warnings} = validate_segment_syntax(segments, element_delimiter, segment_delimiter)
    errors = errors ++ syntax_errors
    warnings = warnings ++ syntax_warnings

    # Count claims
    claim_count = count_claims(segments)

    # Determine transaction type
    transaction_type = detect_transaction_type(segments)

    # Build result
    %{
      valid?: Enum.empty?(errors),
      claim_count: claim_count,
      errors: errors,
      warnings: warnings,
      segment_delimiter: segment_delimiter,
      element_delimiter: element_delimiter,
      transaction_type: transaction_type,
      total_segments: length(segments),
      checked_at: DateTime.utc_now()
    }
  end

  # Delimiter Detection

  defp detect_delimiters(content) do
    # Standard X12 uses ~ for segments and * for elements
    # ISA segment has fixed format: ISA*...data...*~
    segment_delimiter = cond do
      String.contains?(content, "~") -> "~"
      String.contains?(content, "\n") -> "\n"
      String.contains?(content, "|") -> "|"
      true -> "~"  # Default
    end

    # Element delimiter is typically the character after ISA
    element_delimiter = if String.starts_with?(content, "ISA") do
      String.at(content, 3) || "*"
    else
      "*"  # Default
    end

    {segment_delimiter, element_delimiter}
  end

  # Segment Parsing

  defp parse_segments(content, segment_delimiter, element_delimiter) do
    content
    |> String.split(segment_delimiter, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment_str ->
      parse_segment(segment_str, element_delimiter)
    end)
  end

  defp parse_segment(segment_str, element_delimiter) do
    parts = String.split(segment_str, element_delimiter, trim: false)

    case parts do
      [segment_id | elements] ->
        %{
          id: String.upcase(segment_id),
          elements: elements,
          raw: segment_str
        }
      _ ->
        %{id: "", elements: [], raw: segment_str}
    end
  end

  # Envelope Validation

  defp validate_envelope(segments) do
    errors = []
    warnings = []

    # Check for ISA (must be first)
    errors = if not has_segment_at_position?(segments, "ISA", 0) do
      ["Missing ISA segment (Interchange Control Header) - must be first segment" | errors]
    else
      errors
    end

    # Check for IEA (must be last)
    errors = if not has_segment_at_position?(segments, "IEA", -1) do
      ["Missing IEA segment (Interchange Control Trailer) - must be last segment" | errors]
    else
      errors
    end

    # Check for GS
    errors = if not has_segment?(segments, "GS") do
      ["Missing GS segment (Functional Group Header)" | errors]
    else
      errors
    end

    # Check for GE
    errors = if not has_segment?(segments, "GE") do
      ["Missing GE segment (Functional Group Trailer)" | errors]
    else
      errors
    end

    # Check for ST
    errors = if not has_segment?(segments, "ST") do
      ["Missing ST segment (Transaction Set Header) - no transactions found" | errors]
    else
      errors
    end

    # Check for SE
    errors = if not has_segment?(segments, "SE") do
      ["Missing SE segment (Transaction Set Trailer)" | errors]
    else
      errors
    end

    # Validate ST/SE pairs match
    st_count = count_segment(segments, "ST")
    se_count = count_segment(segments, "SE")

    errors = if st_count != se_count do
      ["Unmatched ST/SE segments: found #{st_count} ST but #{se_count} SE segments" | errors]
    else
      errors
    end

    # Validate GS/GE pairs match
    gs_count = count_segment(segments, "GS")
    ge_count = count_segment(segments, "GE")

    errors = if gs_count != ge_count do
      ["Unmatched GS/GE segments: found #{gs_count} GS but #{ge_count} GE segments" | errors]
    else
      errors
    end

    {errors, warnings}
  end

  # Required Segments Validation (for 837)

  defp validate_required_segments(segments) do
    errors = []
    warnings = []

    # Detect transaction type first
    transaction_type = detect_transaction_type(segments)

    # Only validate 837-specific segments if it's an 837
    {errors, warnings} = if transaction_type == "837" do
      errors = if not has_segment?(segments, "BHT") do
        ["Missing required segment: BHT (Beginning of Hierarchical Transaction)" | errors]
      else
        errors
      end

      errors = if not has_segment?(segments, "NM1") do
        ["Missing required segment: NM1 (Individual or Organizational Name)" | errors]
      else
        errors
      end

      errors = if not has_segment?(segments, "CLM") do
        ["Missing required segment: CLM (Claim Information) - no claims found" | errors]
      else
        errors
      end

      {errors, warnings}
    else
      # Non-837 transaction
      warnings = if transaction_type && transaction_type != "837" do
        ["Transaction type #{transaction_type} detected - this system is optimized for 837 (claims)" | warnings]
      else
        warnings
      end

      {errors, warnings}
    end

    {errors, warnings}
  end

  # Segment Syntax Validation

  defp validate_segment_syntax(segments, element_delimiter, segment_delimiter) do
    errors = []
    warnings = []

    # Check each segment has valid ID (2-3 uppercase letters)
    segment_errors = segments
    |> Enum.with_index()
    |> Enum.flat_map(fn {segment, index} ->
      cond do
        segment.id == "" ->
          ["Segment #{index + 1}: Missing segment ID"]

        not Regex.match?(~r/^[A-Z0-9]{2,3}$/, segment.id) ->
          ["Segment #{index + 1}: Invalid segment ID '#{segment.id}' (must be 2-3 uppercase letters/digits)"]

        true ->
          []
      end
    end)

    errors = errors ++ segment_errors

    # Warn about non-standard delimiters
    warnings = if element_delimiter != "*" do
      ["Non-standard element delimiter detected: '#{element_delimiter}' (standard is '*')" | warnings]
    else
      warnings
    end

    warnings = if segment_delimiter != "~" do
      ["Non-standard segment delimiter detected: '#{segment_delimiter}' (standard is '~')" | warnings]
    else
      warnings
    end

    {errors, warnings}
  end

  # Claim Counting

  defp count_claims(segments) do
    # Method 1: Count CLM segments (most accurate for 837)
    clm_count = count_segment(segments, "CLM")

    # Method 2: Count ST segments with type 837 (fallback)
    st_837_count = segments
    |> Enum.filter(fn seg ->
      seg.id == "ST" && Enum.at(seg.elements, 0) == "837"
    end)
    |> length()

    # Use CLM count if available, otherwise use ST count
    if clm_count > 0 do
      clm_count
    else
      st_837_count
    end
  end

  # Transaction Type Detection

  defp detect_transaction_type(segments) do
    # ST segment format: ST*transaction_type*control_number
    segments
    |> Enum.find(fn seg -> seg.id == "ST" end)
    |> case do
      nil -> nil
      st_segment ->
        Enum.at(st_segment.elements, 0)
    end
  end

  # Helper Functions

  defp has_segment?(segments, segment_id) do
    Enum.any?(segments, fn seg -> seg.id == segment_id end)
  end

  defp has_segment_at_position?(segments, segment_id, position) do
    case Enum.at(segments, position) do
      nil -> false
      segment -> segment.id == segment_id
    end
  end

  defp count_segment(segments, segment_id) do
    Enum.count(segments, fn seg -> seg.id == segment_id end)
  end

  @doc """
  Formats a verification result for display to users.
  Returns a human-readable summary string.
  """
  def format_result(%{valid?: true, claim_count: count, warnings: warnings}) do
    warning_text = if Enum.empty?(warnings) do
      ""
    else
      "\n\nWarnings:\n" <> Enum.map_join(warnings, "\n", &("  - #{&1}"))
    end

    "✓ VERIFIED - #{count} claim(s) found#{warning_text}"
  end

  def format_result(%{valid?: false, errors: errors}) do
    "✗ VERIFICATION FAILED\n\n" <>
    "Errors:\n" <>
    Enum.map_join(errors, "\n", &("  - #{&1}"))
  end
end
