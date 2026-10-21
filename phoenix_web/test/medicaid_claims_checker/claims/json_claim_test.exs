defmodule MedicaidClaimsChecker.Claims.JsonClaimTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.JsonClaim

  alias MedicaidClaimsChecker.MockData

  describe "accepts" do
    test "a claim with a top-level claim_id" do
      assert {:ok, [%{"claim_id" => _}], []} =
               JsonClaim.parse(
                 MockData.read!("J_json_files/J1_one_claim/routine_office_visit.json")
               )
    end

    test "the X12 converter's output, normalized" do
      assert {:ok, [claim], []} =
               JsonClaim.parse(
                 MockData.read!("pipeline/converter_output/valid_837p_lab_work.json")
               )

      assert Map.has_key?(claim, "claim_id")
      assert Map.has_key?(claim, "provider")
    end

    test "every generated mock claim file, with all its claims" do
      cases =
        MockData.read!("manifest.json")
        |> Jason.decode!()
        |> Map.fetch!("cases")
        |> Enum.filter(&String.ends_with?(&1["file"], ".json"))

      assert cases != []

      for %{"file" => file, "expect" => %{"claims" => expected}} <- cases do
        assert {:ok, claims, []} = JsonClaim.parse(MockData.read!(file)), "refused #{file}"
        assert length(claims) == length(expected), file
      end
    end

    test "the multi-claim fixtures" do
      assert {:ok, claims, []} =
               JsonClaim.parse(MockData.read!("J_json_files/J3_claims_wrapper/mixed_risk.json"))

      assert length(claims) == 8

      assert {:ok, [%{"claim_id" => "CLM-ROUTINE-001"}, %{"claim_id" => "CLM-HIGHVAL-001"}],
              [{2, _}, {4, _}]} =
               JsonClaim.parse(
                 MockData.read!(
                   "J_json_files/J4_claims_mixed_with_non_claims/list_with_bad_entries.json"
                 )
               )
    end

    test "a bare list of claims, in order" do
      assert {:ok, [%{"claim_id" => "C1"}, %{"claim_id" => "C2"}], []} =
               JsonClaim.parse(~s([{"claim_id": "C1"}, {"claim_id": "C2"}]))
    end

    test "a wrapped list of claims" do
      assert {:ok, [%{"claim_id" => "C1"}, %{"claim_id" => "C2"}], []} =
               JsonClaim.parse(~s({"claims": [{"claim_id": "C1"}, {"claim_id": "C2"}]}))
    end

    test "a list with one claim" do
      assert {:ok, [%{"claim_id" => "C1"}], []} = JsonClaim.parse(~s([{"claim_id": "C1"}]))
    end

    test "the good entries of a list, reporting the bad ones by position" do
      assert {:ok, [%{"claim_id" => "C1"}, %{"claim_id" => "C3"}], refused} =
               JsonClaim.parse(~s([{"claim_id": "C1"}, {"name": "x"}, {"claim_id": "C3"}, 7]))

      assert [{2, "no claim found" <> _}, {4, "not a claim"}] = refused
    end
  end

  describe "refuses" do
    test "an engine test request (rules and a list of claims)" do
      assert {:error, reason} =
               JsonClaim.parse(
                 MockData.read!("J_json_files/J6_engine_request/rules_text_and_claims.json")
               )

      assert reason =~ "engine test request"
    end

    test "an empty list" do
      assert {:error, "the list of claims is empty"} = JsonClaim.parse("[]")
      assert {:error, "the list of claims is empty"} = JsonClaim.parse(~s({"claims": []}))
    end

    test "a list with no claims in it" do
      assert {:error, "none of the 2 entries is a claim"} =
               JsonClaim.parse(~s([{"_id": "A"}, {"_id": "B"}]))
    end

    test "a claims field that is not a list" do
      assert {:error, reason} = JsonClaim.parse(~s({"claims": {"claim_id": "C1"}}))
      assert reason =~ "must be a list"
    end

    test "an object with no claim fields" do
      assert {:error, reason} = JsonClaim.parse(~s({"name": "not a claim"}))
      assert reason =~ "no claim found"
    end

    test "a claim field that is not an object" do
      assert {:error, _} = JsonClaim.parse(~s({"claim": "C1"}))
    end

    test "a scalar" do
      assert {:error, "not a claim"} = JsonClaim.parse("42")
    end

    test "invalid JSON" do
      assert {:error, "not valid JSON"} = JsonClaim.parse("{not json")
    end
  end
end
