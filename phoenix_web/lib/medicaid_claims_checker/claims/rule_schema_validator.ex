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
    "claim_details.statement_from_date",
    "claim_details.statement_to_date",
    "claim_details.admission_date",
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
    "other_codes.*.code",
    "other_codes.*.qualifier",
    "service_lines.*.line_number",
    "service_lines.*.date_of_service",
    "service_lines.*.date_of_service_end",
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

  # Fields worked out from the claim and added to every claim, X12 or JSON,
  # just before it goes to the engine (Claims.PayloadBuilder). They are not
  # in the converter's output.
  @derived_patterns [
    "claim_totals.service_line_total"
  ]

  @doc "The field paths rules may reference (`*` matches any list index)."
  def valid_patterns, do: @valid_patterns ++ @derived_patterns

  @doc "The fields added at evaluation time rather than by the converter."
  def derived_patterns, do: @derived_patterns

  @doc """
  Extracts the field paths a DSL rule text reads, as the engine resolves
  them, with `*` for each list item.

  Strings and `--` comments are skipped. A named quantifier variable
  (`EXISTS line IN service_lines WHERE line.x`) becomes its collection
  (`service_lines.*.x`); inside an unnamed one (`EXISTS service_lines WHERE
  x`) a path is looked up in each item (`service_lines.*.x`). A `WHERE`
  runs to the end of the condition or to the parenthesis closing around
  its quantifier. A single name bound by `LET` stands for its path, and a
  name followed by `(` is a function, not a field. The rule name and the
  action after `THEN` hold no fields.
  """
  @spec field_references(String.t()) :: [String.t()]
  def field_references(rule_text) when is_binary(rule_text) do
    rule_text |> scan_references() |> Enum.map(& &1.path) |> Enum.uniq()
  end

  @doc """
  Validates all field references in `rule_text` against the known claim contract.

  Returns `{:ok, %{references: [...], issues: []}}` when all paths are valid, or
  `{:error, %{references: [...], issues: [%{reference:, suggested:, message:}]}}` when
  unknown paths are found. Suggestions include the closest valid alternative when one exists.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, map()}
  def validate(rule_text) when is_binary(rule_text) do
    scanned = rule_text |> scan_references() |> Enum.uniq_by(& &1.path)

    issues =
      Enum.flat_map(scanned, fn %{path: reference} = ref ->
        if known?(reference) do
          []
        else
          suggested = if ref.in_item, do: nil, else: suggest_path(reference)

          [
            %{
              reference: reference,
              suggested: suggested,
              hint: in_item_hint(ref),
              message: drift_message(ref, suggested)
            }
          ]
        end
      end)

    details = %{references: Enum.map(scanned, & &1.path), issues: issues}

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
      %{reference: reference, hint: hint} when is_binary(hint) -> "#{reference} (#{hint})"
      %{reference: reference, suggested: nil} -> reference
      %{reference: reference, suggested: suggested} -> "#{reference} -> #{suggested}"
    end)
    |> Enum.join("; ")
  end

  # A field, or a section or list that holds fields (`patient`, the
  # collection in `COUNT(service_lines)`).
  defp known?(reference) do
    Enum.any?(valid_patterns(), fn pattern ->
      path_matches?(reference, pattern) or section_of?(reference, pattern)
    end)
  end

  defp section_of?(reference, pattern) do
    ref_parts = String.split(reference, ".")
    pat_parts = String.split(pattern, ".")

    length(ref_parts) < length(pat_parts) and
      path_matches?(reference, pat_parts |> Enum.take(length(ref_parts)) |> Enum.join("."))
  end

  # --- Scanning a rule ---------------------------------------------------

  @keywords ~w(RULE DESCRIPTION WHEN THEN END TRUE FALSE AND OR NOT WHERE EXISTS
               FORALL COUNT LET IS NULL BETWEEN IN CONTAINS MATCHES
               REJECT FLAG_FRAUD REQUIRE_REVIEW APPROVE RISK_SCORE)

  # `claim.has_diagnosis "code"` and `claim.has_procedure "code"`.
  @helper_calls ~w(claim.has_diagnosis claim.has_procedure)

  # Tokens: :lparen, :rparen, :semicolon, {:name, "a.b.c"}. Strings, comments,
  # numbers and operators are dropped.
  defp tokenize(text) do
    ~r/"[^"]*"|--[^\n]*|[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*|[();]/
    |> Regex.scan(text)
    |> Enum.flat_map(fn
      ["\"" <> _] -> []
      ["--" <> _] -> []
      ["("] -> [:lparen]
      [")"] -> [:rparen]
      [";"] -> [:semicolon]
      [word] -> if Regex.match?(~r/^[0-9.]+$/, word), do: [], else: [{:name, word}]
    end)
  end

  defp scan_references(text) do
    text |> tokenize() |> scan(new_rule_state(), []) |> Enum.reverse()
  end

  defp new_rule_state, do: %{depth: 0, scopes: [], lets: %{}, in_action: false}

  defp scan([], _st, acc), do: acc

  # A new rule: skip its name; its LET names and scopes are its own.
  defp scan([{:name, "RULE"}, {:name, _name} | rest], _st, acc),
    do: scan(rest, new_rule_state(), acc)

  defp scan([{:name, "RULE"} | rest], _st, acc), do: scan(rest, new_rule_state(), acc)

  # The action holds no field paths.
  defp scan([_ | rest], %{in_action: true} = st, acc), do: scan(rest, st, acc)

  defp scan([{:name, "THEN"} | rest], st, acc),
    do: scan(rest, %{st | in_action: true, scopes: []}, acc)

  defp scan([{:name, "LET"}, {:name, name}, {:name, path} | rest], st, acc) do
    ref = resolve(path, st)
    scan(rest, %{st | lets: Map.put(st.lets, name, ref.path)}, [ref | acc])
  end

  # EXISTS var IN collection WHERE ... / EXISTS collection WHERE ...
  defp scan(
         [{:name, q}, {:name, var}, {:name, "IN"}, {:name, coll}, {:name, "WHERE"} | rest],
         st,
         acc
       )
       when q in ["EXISTS", "FORALL"] do
    ref = resolve(coll, st)
    scope = %{depth: st.depth, var: var, prefix: ref.path <> ".*"}
    scan(rest, %{st | scopes: [scope | st.scopes]}, [ref | acc])
  end

  defp scan([{:name, q}, {:name, coll}, {:name, "WHERE"} | rest], st, acc)
       when q in ["EXISTS", "FORALL"] do
    ref = resolve(coll, st)
    scope = %{depth: st.depth, var: nil, prefix: ref.path <> ".*"}
    scan(rest, %{st | scopes: [scope | st.scopes]}, [ref | acc])
  end

  defp scan([:lparen | rest], st, acc), do: scan(rest, %{st | depth: st.depth + 1}, acc)

  # A closing parenthesis ends every quantifier opened inside it.
  defp scan([:rparen | rest], st, acc) do
    depth = st.depth - 1
    scan(rest, %{st | depth: depth, scopes: Enum.reject(st.scopes, &(&1.depth > depth))}, acc)
  end

  defp scan([:semicolon | rest], st, acc), do: scan(rest, %{st | in_action: false}, acc)

  defp scan([{:name, word} | rest], st, acc) when word in @keywords or word in @helper_calls,
    do: scan(rest, st, acc)

  # name(...) is a helper function, such as is_weekend or claim.has_diagnosis.
  defp scan([{:name, _function}, :lparen | rest], st, acc),
    do: scan([:lparen | rest], st, acc)

  defp scan([{:name, path} | rest], st, acc), do: scan(rest, st, [resolve(path, st) | acc])

  # Resolves a path the way the engine does: a quantifier variable first,
  # then a single LET name, then the current document (the item of the
  # innermost unnamed quantifier, or the claim).
  defp resolve(path, st) do
    [first | rest] = parts = String.split(path, ".")

    case Enum.find(st.scopes, &(&1.var == first)) do
      %{prefix: prefix} ->
        %{path: Enum.join([prefix | rest], "."), in_item: false}

      nil ->
        case {parts, Map.fetch(st.lets, first)} do
          {[_single], {:ok, let_path}} ->
            %{path: let_path, in_item: false}

          _ ->
            case Enum.find(st.scopes, &is_nil(&1.var)) do
              %{prefix: prefix} -> %{path: prefix <> "." <> path, in_item: path}
              nil -> %{path: path, in_item: false}
            end
        end
    end
  end

  defp suggest_path(reference) do
    renamed =
      Enum.find_value(@renamed, fn {old, new} -> if path_matches?(reference, old), do: new end)

    cond do
      renamed ->
        renamed

      String.starts_with?(reference, "claim.") ->
        stripped = String.replace_prefix(reference, "claim.", "")

        cond do
          Enum.any?(valid_patterns(), &path_matches?(stripped, &1)) -> stripped
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
      when root in ["diagnosis_codes", "other_codes", "procedure_codes", "service_lines"] and
             rest != [] ->
        candidate = Enum.join([root, "*" | rest], ".")

        if Enum.any?(valid_patterns(), &path_matches?(candidate, &1)), do: candidate, else: nil

      _ ->
        nil
    end
  end

  # A claim-level path written inside an unnamed quantifier is looked up in
  # each item, where it isn't (SYNTAX_GUIDE "How far a WHERE reaches").
  defp in_item_hint(%{in_item: written}) when is_binary(written) do
    if known?(written),
      do: "#{written} is read inside each item here; put parentheses around the EXISTS/FORALL"
  end

  defp in_item_hint(_ref), do: nil

  defp drift_message(%{path: reference} = ref, nil) do
    case in_item_hint(ref) do
      nil -> "Unknown field reference: #{reference}"
      hint -> "Unknown field reference: #{reference} (#{hint})"
    end
  end

  defp drift_message(%{path: reference}, suggested),
    do: "Unknown field reference: #{reference} (did you mean #{suggested}?)"

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
