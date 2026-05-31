defmodule MedicaidClaimsChecker.Claims.RuleSchemaValidator do
  @moduledoc """
  Validates DSL field references against the claim contract supported by the
  current application.

  This is a schema-drift guard after syntax parsing succeeds. It accepts the
  field paths and loop/segment forms already used by the app's fixtures and X12
  translator, and it flags references that do not map to any known contract
  shape.
  """

  @valid_patterns [
    "claim_id",
    "claim.claim_id",
    "claim_header.claim_control_number",
    "claim_header.claim_submission_reason",
    "claim_header.claim_type",
    "claim_header.patient_control_number",
    "claim_details.admission_date",
    "claim_details.discharge_date",
    "claim_details.admission_type",
    "claim_details.admission_source",
    "claim_details.discharge_status",
    "claim_details.patient_status",
    "claim_details.service_type",
    "claim_details.place_of_service",
    "provider.name",
    "provider.npi",
    "provider.tax_id",
    "provider.type",
    "provider.address.street",
    "provider.address.city",
    "provider.address.state",
    "provider.address.postal_code",
    "provider.address.country",
    "provider.contact.phone",
    "provider.contact.fax",
    "provider.tenure_days",
    "provider.risk_score",
    "provider.credentialing_date",
    "provider.specialty",
    "provider.taxonomy",
    "billing_provider.npi",
    "billing_provider.taxonomy",
    "billing_provider.name",
    "billing_provider.address.street",
    "billing_provider.address.city",
    "billing_provider.address.state",
    "billing_provider.address.postal_code",
    "patient.name.first",
    "patient.name.middle",
    "patient.name.last",
    "patient.name.suffix",
    "patient.date_of_birth",
    "patient.gender",
    "patient.patient_id",
    "patient.ssn",
    "patient.address.street",
    "patient.address.city",
    "patient.address.state",
    "patient.address.postal_code",
    "patient.address.country",
    "patient.contact.phone",
    "patient.contact.email",
    "subscriber.subscriber_id",
    "subscriber.relationship",
    "subscriber.group_number",
    "subscriber.date_of_birth",
    "subscriber.plan_id",
    "payer.payer_id",
    "payer.payer_name",
    "payer.address.street",
    "payer.address.city",
    "payer.address.state",
    "payer.address.postal_code",
    "payer.contact.phone",
    "diagnosis_codes.*.code",
    "diagnosis_codes.*.description",
    "diagnosis_codes.*.qualifier",
    "diagnosis_codes.*.present_on_admission",
    "procedure_codes.*.code",
    "procedure_codes.*.description",
    "procedure_codes.*.units",
    "procedure_codes.*.date_performed",
    "service_lines.*.service_line_number",
    "service_lines.*.procedure_code",
    "service_lines.*.description",
    "service_lines.*.units",
    "service_lines.*.unit_rate",
    "service_lines.*.line_amount",
    "service_lines.*.date_of_service",
    "service_lines.*.place_of_service",
    "service_lines.*.diagnosis_pointers.*",
    "claim_totals.total_submitted",
    "claim_totals.total_charges",
    "claim_totals.total_patient_responsibility",
    "claim_totals.total_payer_liability",
    "claim_totals.total_units",
    "financial.claim_amount",
    "financial.patient_deductible",
    "financial.patient_coinsurance",
    "financial.patient_copay",
    "financial.coordination_of_benefits",
    "authorization.authorization_number",
    "authorization.authorization_date",
    "authorization.authorization_period_start",
    "authorization.authorization_period_end",
    "authorization.authorization_status",
    "authorization.authorized_amount",
    "authorization.approved_units",
    "claim_metadata.submission_date",
    "claim_metadata.claim_frequency",
    "claim_metadata.claim_received_date",
    "claim_metadata.claim_processing_status",
    "claim_metadata.test_rule",
    "claim_metadata.expected_result",
    "rendering_provider.npi",
    "claim.rendering_provider.npi",
    "rendering_provider.taxonomy_code",
    "rendering_provider.last_name",
    "rendering_provider.first_name",
    "rendering_provider.middle_name",
    "attending_provider.npi",
    "attending_provider.taxonomy_code",
    "attending_provider.last_name",
    "attending_provider.first_name",
    "attending_provider.middle_name",
    "institutional_claim.admission_type",
    "institutional_claim.admission_source",
    "institutional_claim.patient_status",
    "dates.onset_date",
    "dates.admission_date",
    "dates.discharge_date",
    "dates.service_date",
    "dates.accident_date",
    "2300.CLM.claim_amount",
    "2300.CLM.facility_type",
    "2400.SV1.place_of_service",
    "2400.SV1.line_charge",
    "2400.SV1.procedure_code",
    "2400.DTP.service_day_of_week",
    "2400.DTP.service_date",
    "2300.HI.diagnosis_code",
    "2010.NM1.patient_age",
    "CLM.claim_amount",
    "claim.total_charge_amount",
    "claim.subscriber.date_of_birth"
  ]

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
    cond do
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
    Regex.scan(~r/\b(?:[A-Za-z_][A-Za-z0-9_]*|\d+)(?:\.[A-Za-z0-9_]+)+\b/u, text)
    |> List.flatten()
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
