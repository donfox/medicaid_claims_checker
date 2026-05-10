defmodule MedicaidClaimsChecker.Claims.RuleSchemaValidatorTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.RuleSchemaValidator

  test "accepts current contract paths and helper-aware rules" do
    rule_text = """
    RULE valid_rule
    DESCRIPTION "Valid rule"
    LET amount = 2300.CLM.claim_amount
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
end
