defmodule MedicaidClaimsChecker.Claims.RuleSchemaValidatorTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.RuleSchemaValidator
  alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}

  @x12_suite Path.expand("../../fixtures/x12_suite/files", __DIR__)

  test "accepts current contract paths and helper-aware rules" do
    rule_text = """
    RULE valid_rule
    DESCRIPTION "Valid rule"
    WHEN financial.claim_amount > 5000
         AND EXISTS line IN service_lines WHERE line.procedure_code = "99213"
         AND claim.has_diagnosis("E11.9")
    THEN REQUIRE_REVIEW "review"
    END
    """

    assert {:ok, %{references: references}} = RuleSchemaValidator.validate(rule_text)
    assert "financial.claim_amount" in references
    assert "service_lines.*.procedure_code" in references
    refute Enum.any?(references, &String.contains?(&1, "claim.has_diagnosis"))
  end

  test "flags schema drift for paths that do not exist in the current contract" do
    rule_text = """
    RULE drift_rule
    DESCRIPTION "Drift rule"
      WHEN claim.nonexistent_field IS NOT NULL
        OR claim.rendering_provider.unknown IS NULL
    THEN REJECT "bad"
    END
    """

    assert {:error, %{issues: issues}} = RuleSchemaValidator.validate(rule_text)
    assert Enum.any?(issues, &(&1.reference == "claim.nonexistent_field"))
    assert Enum.any?(issues, &(&1.reference == "claim.rendering_provider.unknown"))
    assert RuleSchemaValidator.format_issues(issues) =~ "claim.nonexistent_field"
  end

  test "expands named quantifier variables to the underlying collection path" do
    rule_text = """
    RULE quantifier_rule
    DESCRIPTION "Quantifier rule"
    WHEN EXISTS line IN service_lines WHERE line.procedure_code = "99213"
    THEN FLAG_FRAUD "x"
    END
    """

    assert {:ok, %{references: references}} = RuleSchemaValidator.validate(rule_text)
    assert "service_lines.*.procedure_code" in references
  end

  test "a decimal literal is a number, not a field reference" do
    rule_text = """
    RULE decimals "Decimal thresholds"
    WHEN financial.claim_amount > 50000.0
      AND FORALL line IN service_lines WHERE line.charge_amount > 500.25
    THEN FLAG_FRAUD "x";
    """

    assert {:ok, %{references: references}} = RuleSchemaValidator.validate(rule_text)
    assert Enum.sort(references) == ["financial.claim_amount", "service_lines.*.charge_amount"]
  end

  test "flags X12 loop-style paths and names the converted-claim field" do
    rule_text = """
    RULE loop_rule
    DESCRIPTION "Written against the raw X12 layout"
    WHEN 2300.CLM.claim_amount > 50000
      OR 2400.SV1.place_of_service = "21"
      OR 2300.CLM.facility_type = "11"
    THEN REQUIRE_REVIEW "x"
    END
    """

    assert {:error, %{issues: issues}} = RuleSchemaValidator.validate(rule_text)
    by_ref = Map.new(issues, &{&1.reference, &1.suggested})
    assert by_ref["2300.CLM.claim_amount"] == "financial.claim_amount"
    assert by_ref["2400.SV1.place_of_service"] == "service_lines.*.place_of_service"
    # The converter keeps no facility type, so there is nothing to suggest.
    assert Map.fetch!(by_ref, "2300.CLM.facility_type") == nil
  end

  test "accepts fields the converter produces that the old list refused" do
    rule_text = """
    RULE converter_fields
    DESCRIPTION "Converter field names"
    WHEN EXISTS line IN service_lines WHERE line.charge_amount > 1000
      AND payer.name = "STATE MEDICAID"
      AND subscriber.member_id IS NOT NULL
      AND billing_provider.address.zip IS NOT NULL
    THEN REQUIRE_REVIEW "x"
    END
    """

    assert {:ok, _} = RuleSchemaValidator.validate(rule_text)
  end

  test "suggests the converter's name for a near-miss field" do
    rule_text = """
    RULE near_miss
    DESCRIPTION "Old field names"
    WHEN EXISTS line IN service_lines WHERE line.line_amount > 1000
      AND payer.payer_name = "X"
    THEN REQUIRE_REVIEW "x"
    END
    """

    assert {:error, %{issues: issues}} = RuleSchemaValidator.validate(rule_text)
    by_ref = Map.new(issues, &{&1.reference, &1.suggested})
    assert by_ref["service_lines.*.line_amount"] == "service_lines.*.charge_amount"
    assert by_ref["payer.payer_name"] == "payer.name"
  end

  test "the field list is exactly the converter's output for the X12 suite" do
    produced =
      Path.wildcard(Path.join(@x12_suite, "**/*.{x12,edi}"))
      |> Enum.flat_map(&converted_claims/1)
      |> Enum.flat_map(&leaf_paths(&1, []))
      |> MapSet.new()

    # A section that is nil on some claims (no rendering provider, say) shows
    # up as a bare path; it is a parent of real fields, not a field itself.
    produced = MapSet.reject(produced, fn path -> Enum.any?(produced, &String.starts_with?(&1, path <> ".")) end)

    assert MapSet.size(produced) > 50
    listed = MapSet.new(RuleSchemaValidator.valid_patterns())

    refused = MapSet.difference(produced, listed) |> Enum.sort()
    assert refused == [], "the converter produces fields the Rules page would refuse: #{inspect(refused)}"

    stale = MapSet.difference(listed, produced) |> Enum.sort()
    assert stale == [], "the Rules page accepts fields no converted claim has: #{inspect(stale)}"
  end

  defp converted_claims(path) do
    content = File.read!(path)

    transaction_sets =
      case ClaimSplitter.split_transaction_sets(content) do
        {:ok, sets} when is_list(sets) -> sets
        _ -> [content]
      end

    Enum.flat_map(transaction_sets, fn set ->
      claims =
        case ClaimSplitter.split_claims_to_x12(set) do
          {:ok, claims} when is_list(claims) -> Enum.map(claims, & &1.x12_content)
          _ -> [set]
        end

      Enum.flat_map(claims, fn x12 ->
        with {:ok, flat} <- Converter.convert_content(x12),
             {:ok, claim} <- SegmentMapper.map_from_json(flat) do
          [claim]
        else
          _ -> []
        end
      end)
    end)
  end

  # Paths to non-map values; list elements become "*". Empty lists and maps
  # contribute nothing, as a rule can't reference a field inside them.
  defp leaf_paths(map, prefix) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> leaf_paths(v, prefix ++ [to_string(k)]) end)

  defp leaf_paths(list, prefix) when is_list(list) and list != [],
    do: Enum.flat_map(list, &leaf_paths(&1, prefix ++ ["*"]))

  defp leaf_paths([], _prefix), do: []
  defp leaf_paths(_value, prefix), do: [Enum.join(prefix, ".")]
end
