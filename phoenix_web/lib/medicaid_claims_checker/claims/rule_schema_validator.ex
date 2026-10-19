defmodule MedicaidClaimsChecker.Claims.RuleSchemaValidator do
  @moduledoc """
  Validates DSL field references against the claim contract: the claim JSON
  that `X12.SegmentMapper` produces from an 837, which is what rules see.

  This is a schema-drift guard after syntax parsing succeeds. A rule naming a
  field no converted claim has would never fire (or always be "not checked"),
  so the Rules page saves it as a draft and won't activate it. X12 loop-style
  paths such as `2300.CLM.claim_amount` name where a value sits in the raw
  file, not in the converted claim, so they are flagged with the field to use
  instead. `test/medicaid_claims_checker/claims/rule_schema_validator_test.exs`
  checks this list against the converter's output for the whole X12 suite.
  """

  # Every leaf path in a converted claim. `*` matches any list index.
  @valid_patterns [
    "claim_id",
    "transaction_type",
    "claim_details.place_of_service",
    "claim_details.facility_type_code",
    "claim_details.frequency_code",
    "financial.claim_amount",
    "claim_totals.total_charges",
    "authorization.authorization_number",
    "provider.name",
    "provider.npi",
    "provider.tax_id",
    "provider.taxonomy",
    "provider.tenure_days",
    "billing_provider.name",
    "billing_provider.npi",
    "billing_provider.tax_id",
    "billing_provider.taxonomy",
    "billing_provider.address.street",
    "billing_provider.address.city",
    "billing_provider.address.state",
    "billing_provider.address.zip",
    "rendering_provider.npi",
    "rendering_provider.taxonomy_code",
    "rendering_provider.last_name",
    "rendering_provider.first_name",
    "rendering_provider.middle_name",
    "patient.name.first",
    "patient.name.middle",
    "patient.name.last",
    "patient.date_of_birth",
    "patient.gender",
    "subscriber.member_id",
    "subscriber.last_name",
    "subscriber.first_name",
    "subscriber.middle_name",
    "subscriber.date_of_birth",
    "subscriber.gender",
    "subscriber.relationship_code",
    "subscriber.group_number",
    "subscriber.payer_responsibility",
    "subscriber.address.street",
    "subscriber.address.city",
    "subscriber.address.state",
    "subscriber.address.zip",
    "payer.name",
    "payer.payer_id",
    "diagnosis_codes.*.code",
    "diagnosis_codes.*.qualifier",
    "service_lines.*.line_number",
    "service_lines.*.date_of_service",
    "service_lines.*.place_of_service",
    "service_lines.*.procedure_code",
    "service_lines.*.procedure_qualifier",
    "service_lines.*.charge_amount",
    "service_lines.*.units",
    "service_lines.*.unit_type",
    "service_lines.*.diagnosis_pointer",
    "service_lines.*.revenue_code",
    "service_lines.*.tooth_info.tooth_code_qualifier",
    "service_lines.*.tooth_info.tooth_number",
    "service_lines.*.tooth_info.tooth_surface",
    "submitter.name",
    "submitter.id",
    "submitter.contact_name",
    "submitter.contact_phone",
    "receiver.name",
    "receiver.id",
    "interchange.control_number",
    "interchange.sender_id",
    "interchange.receiver_id",
    "interchange.date",
    "interchange.time",
    "interchange.version",
    "interchange.usage_indicator",
    "functional_group.functional_id_code",
    "functional_group.sender_code",
    "functional_group.receiver_code",
    "functional_group.version"
  ]

  # Loop-style paths and earlier field names, with the converted-claim field
  # that holds the same value. A loop path with no equivalent gets no hint.
  @renamed %{
    "2300.CLM.claim_amount" => "financial.claim_amount",
    "2300.CLM.facility_type" => "claim_details.facility_type_code",
    "CLM.claim_amount" => "financial.claim_amount",
    "claim.total_charge_amount" => "claim_totals.total_charges",
    "2300.HI.diagnosis_code" => "diagnosis_codes.*.code",
    "2400.SV1.place_of_service" => "service_lines.*.place_of_service",
    "2400.SV1.procedure_code" => "service_lines.*.procedure_code",
    "2400.SV1.line_charge" => "service_lines.*.charge_amount",
    "2400.DTP.service_date" => "service_lines.*.date_of_service",
    "claim.subscriber.date_of_birth" => "subscriber.date_of_birth",
    "claim.rendering_provider.npi" => "rendering_provider.npi",
    "service_lines.*.line_amount" => "service_lines.*.charge_amount",
    "service_lines.*.service_line_number" => "service_lines.*.line_number",
    "claim_totals.total_submitted" => "claim_totals.total_charges",
    "payer.payer_name" => "payer.name",
    "subscriber.subscriber_id" => "subscriber.member_id",
    "subscriber.relationship" => "subscriber.relationship_code",
    "billing_provider.address.postal_code" => "billing_provider.address.zip"
  }

  @doc "The converted-claim field paths rules may reference (`*` matches any list index)."
  def valid_patterns, do: @valid_patterns

  @helper_calls MapSet.new(["claim.has_diagnosis", "claim.has_procedure"])

  @doc "Extracts all field path references from a DSL rule string, with quantifier bindings expanded."
  @spec field_references(String.t()) :: [String.t()]
  def field_references(rule_text) when is_binary(rule_text) do
    sanitized_text = strip_string_literals(rule_text)
    bindings = extract_quantifier_bindings(sanitized_text)

    sanitized_text
    |> extract_references(bindings)
    |> Enum.uniq()
  end

  @doc """
  Validates all field references in `rule_text` against the known claim contract.

  Returns `{:ok, %{references: [...], issues: []}}` when all paths are valid, or
  `{:error, %{references: [...], issues: [%{reference:, suggested:, message:}]}}` when
  unknown paths are found. Suggestions include the closest valid alternative when one exists.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, map()}
  def validate(rule_text) when is_binary(rule_text) do
    references = field_references(rule_text)

    issues =
      references
      |> Enum.flat_map(fn reference ->
        case classify_reference(reference) do
          {:ok, _pattern} ->
            []

          {:error, suggested} ->
            [
              %{
                reference: reference,
                suggested: suggested,
                message: drift_message(reference, suggested)
              }
            ]
        end
      end)

    details = %{references: references, issues: issues}

    case issues do
      [] -> {:ok, details}
      _ -> {:error, details}
    end
  end

  @spec format_issues([map()]) :: String.t()
  def format_issues([]), do: ""

  def format_issues(issues) when is_list(issues) do
    issues
    |> Enum.map(fn
      %{reference: reference, suggested: nil} -> reference
      %{reference: reference, suggested: suggested} -> "#{reference} -> #{suggested}"
    end)
    |> Enum.join("; ")
  end

  defp classify_reference(reference) do
    case Enum.find(@valid_patterns, &path_matches?(reference, &1)) do
      nil -> {:error, suggest_path(reference)}
      pattern -> {:ok, pattern}
    end
  end

  defp suggest_path(reference) do
    renamed = Enum.find_value(@renamed, fn {old, new} -> if path_matches?(reference, old), do: new end)

    cond do
      renamed -> renamed

      String.starts_with?(reference, "claim.") ->
        stripped = String.replace_prefix(reference, "claim.", "")

        cond do
          Enum.any?(@valid_patterns, &path_matches?(stripped, &1)) -> stripped
          candidate = wildcard_variant(stripped) -> candidate
          true -> nil
        end

      true ->
        wildcard_variant(reference)
    end
  end

  defp wildcard_variant(reference) do
    reference
    |> String.split(".")
    |> case do
      [root | rest]
      when root in ["diagnosis_codes", "procedure_codes", "service_lines"] and rest != [] ->
        candidate = Enum.join([root, "*" | rest], ".")

        if Enum.any?(@valid_patterns, &path_matches?(candidate, &1)), do: candidate, else: nil

      _ ->
        nil
    end
  end

  defp drift_message(reference, nil), do: "Unknown field reference: #{reference}"

  defp drift_message(reference, suggested),
    do: "Unknown field reference: #{reference} (did you mean #{suggested}?)"

  defp strip_string_literals(text) do
    Regex.replace(~r/"(?:\\.|[^"])*"/s, text, "")
  end

  defp extract_quantifier_bindings(text) do
    Regex.scan(
      ~r/\b(?:EXISTS|FORALL)\s+([A-Za-z_][A-Za-z0-9_]*)\s+IN\s+([A-Za-z0-9_\.]+)\s+WHERE\b/i,
      text,
      capture: :all_but_first
    )
    |> Enum.reduce(%{}, fn [var_name, path], acc -> Map.put(acc, var_name, path) end)
  end

  defp extract_references(text, bindings) do
    # Paths may start with digits so loop-style paths (2300.CLM...) are caught
    # and flagged, but a decimal literal such as 50000.0 is not a path.
    Regex.scan(~r/\b(?:[A-Za-z_][A-Za-z0-9_]*|\d+)(?:\.[A-Za-z0-9_]+)+\b/u, text)
    |> List.flatten()
    |> Enum.reject(&Regex.match?(~r/^\d+(\.\d+)*$/, &1))
    |> Enum.reject(&MapSet.member?(@helper_calls, &1))
    |> Enum.map(&expand_quantifier_reference(&1, bindings))
  end

  defp expand_quantifier_reference(reference, bindings) do
    case String.split(reference, ".", parts: 2) do
      [var_name, remainder] ->
        if Map.has_key?(bindings, var_name) do
          bindings[var_name] <> ".*." <> remainder
        else
          reference
        end

      _ ->
        reference
    end
  end

  defp path_matches?(reference, pattern) do
    ref_parts = String.split(reference, ".")
    pat_parts = String.split(pattern, ".")

    length(ref_parts) == length(pat_parts) and
      Enum.zip(ref_parts, pat_parts)
      |> Enum.all?(fn
        {_, "*"} -> true
        {ref_part, pat_part} -> ref_part == pat_part
      end)
  end
end
