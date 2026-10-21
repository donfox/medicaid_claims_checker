defmodule MedicaidClaimsCheckerWeb.UseCases.JJsonFilesTest do
  @moduledoc "J1–J8: uploading .json files."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  manifest_tests(~w(J1 J2 J3 J4 J5 J6 J7 J8))

  @tag use_case: "J1"
  test "J1 routine_office_visit.json: one claim is evaluated", %{conn: conn} do
    %{claims: claims, message: message} =
      upload(conn, ["J_json_files/J1_one_claim/routine_office_visit.json"])

    assert [%{status: "evaluated"}] = Map.values(claims)
    assert message =~ "1 claim(s)"
  end

  @tag use_case: "J3"
  test ~s|J3 mixed_risk.json: every claim in {"claims": [...]} is evaluated|, %{conn: conn} do
    rel = "J_json_files/J3_claims_wrapper/mixed_risk.json"

    count =
      rel
      |> MedicaidClaimsChecker.MockData.read!()
      |> Jason.decode!()
      |> Map.fetch!("claims")
      |> length()

    %{claims: claims} = upload(conn, [rel])

    assert map_size(claims) == count
    assert Enum.all?(Map.values(claims), &(&1.status == "evaluated"))
  end

  @tag use_case: "J4"
  test "J4 list_with_bad_entries.json: claims are evaluated, the other entries named and refused",
       %{conn: conn} do
    rel = "J_json_files/J4_claims_mixed_with_non_claims/list_with_bad_entries.json"

    {:ok, good, refused} =
      rel
      |> MedicaidClaimsChecker.MockData.read!()
      |> MedicaidClaimsChecker.Claims.JsonClaim.parse()

    assert good != [] and refused != []

    %{claims: claims, message: message} = upload(conn, [rel])

    assert map_size(claims) == length(good)
    assert Enum.all?(Map.values(claims), &(&1.status == "evaluated"))
    assert message =~ "Not accepted: list_with_bad_entries.json (entry"
  end

  @tag use_case: "J6"
  test "J6 rules_text_and_claims.json: an engine request is refused, nothing evaluated", %{
    conn: conn
  } do
    %{claims: claims, message: message} =
      upload(conn, ["J_json_files/J6_engine_request/rules_text_and_claims.json"])

    assert claims == %{}
    assert message =~ "an engine test request"
  end
end
