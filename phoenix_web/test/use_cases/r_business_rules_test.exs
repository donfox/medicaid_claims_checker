defmodule MedicaidClaimsCheckerWeb.UseCases.RBusinessRulesTest do
  @moduledoc "R1–R11: what the seeded business rules match, through a real upload."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  alias MedicaidClaimsChecker.{Claims, MockData}

  manifest_tests(~w(R1 R2 R3 R4 R5 R6 R7 R9 R10 R11))

  # R8: provider tenure comes only from JSON claims (X12 has no credentialing date).
  manifest_tests_as("R8", [
    "claim_rule_checks/each_rule_alone/NewProviderLargeSubmission.json",
    "claim_rule_checks/each_rule_alone/MissingTaxonomyNewProvider.json"
  ])

  @tag use_case: "R2"
  test "R2 a rule on procedure modifiers matches X12 and both JSON forms", %{conn: conn} do
    {:ok, _} =
      Claims.create_business_rule(%{
        name: "modifier_25",
        active: true,
        rule_text: """
        RULE modifier_25
        DESCRIPTION "Modifier 25"
        WHEN EXISTS line IN service_lines WHERE EXISTS m IN line.modifiers WHERE m.code = "25"
        THEN REQUIRE_REVIEW "Modifier 25"
        END
        """
      })

    x12 =
      "x12_files/837p_professional/clean_office_visit.x12"
      |> MockData.read!()
      |> String.replace("HC:99213*", "HC:99213:25*")

    json = "claim_rule_checks/clean_claim/office_visit.json" |> MockData.read!() |> Jason.decode!()

    json_with = fn id, modifiers ->
      lines = Enum.map(json["service_lines"], &Map.put(&1, "modifiers", modifiers))
      {"#{id}.json", json |> Map.merge(%{"claim_id" => id, "service_lines" => lines}) |> Jason.encode!()}
    end

    %{claims: claims} =
      upload(conn, [
        {"modifier.x12", x12},
        json_with.("MOD-PLAIN", ["25"]),
        json_with.("MOD-OBJECT", [%{"code" => "25"}]),
        json_with.("MOD-OTHER", ["59"])
      ])

    matched? = &MapSet.member?(claims[&1].matched, "modifier_25")
    assert matched?.("CLEAN001")
    assert matched?.("MOD-PLAIN")
    assert matched?.("MOD-OBJECT")
    refute matched?.("MOD-OTHER")
  end
end
