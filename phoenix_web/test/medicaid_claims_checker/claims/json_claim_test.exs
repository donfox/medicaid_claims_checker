defmodule MedicaidClaimsChecker.Claims.JsonClaimTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.JsonClaim

  @fixtures Path.expand("../../fixtures/json_upload", __DIR__)
  # Hand-made claims for manual testing in the UI; each must stay uploadable.
  @mock_claims Path.expand("../../../../mock_data/claims", __DIR__)

  defp fixture(path), do: File.read!(Path.join(@fixtures, path))

  describe "accepts" do
    test "a claim with a top-level claim_id" do
      assert {:ok, [%{"claim_id" => _}], []} =
               JsonClaim.parse(fixture("claim_routine_office_visit.json"))
    end

    test "the X12 converter's output, normalized" do
      assert {:ok, [claim], []} =
               JsonClaim.parse(
                 File.read!(Path.expand("../../fixtures/converter_output/valid_837p_lab_work.json", __DIR__))
               )

      assert Map.has_key?(claim, "claim_id")
      assert Map.has_key?(claim, "provider")
    end

    test "every mock claim" do
      paths = Path.wildcard(Path.join(@mock_claims, "**/*.json"))
      assert paths != []

      for path <- paths do
        assert {:ok, [_], []} = JsonClaim.parse(File.read!(path)), "refused #{path}"
      end
    end

    test "the multi-claim fixtures" do
      assert {:ok, claims, []} = JsonClaim.parse(fixture("claims_list_mixed_risk.json"))
      assert length(claims) == 8

      assert {:ok, [%{"claim_id" => "CLM-ROUTINE-001"}, %{"claim_id" => "CLM-HIGHVAL-001"}],
              [{2, _}, {4, _}]} =
               JsonClaim.parse(fixture("claims_list_with_bad_entries.json"))
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
      assert {:error, reason} = JsonClaim.parse(fixture("batch_redundancy_extended.json"))
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
