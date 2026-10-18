defmodule MedicaidClaimsChecker.Claims.JsonClaimTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.JsonClaim

  @fixtures Path.expand("../../fixtures", __DIR__)

  defp fixture(path), do: File.read!(Path.join(@fixtures, path))

  describe "accepts" do
    test "a claim with a top-level claim_id" do
      assert {:ok, %{"claim_id" => _}} =
               JsonClaim.parse(fixture("claims/acceptable/claim_routine_office_visit.json"))
    end

    test "the X12 converter's output, normalized" do
      assert {:ok, claim} = JsonClaim.parse(fixture("x12/valid_837p_lab_work.json"))
      assert Map.has_key?(claim, "claim_id")
      assert Map.has_key?(claim, "provider")
    end

    test "every claim fixture" do
      for path <- Path.wildcard(Path.join(@fixtures, "claims/**/*.json")) do
        assert {:ok, _} = JsonClaim.parse(File.read!(path)), "refused #{path}"
      end
    end
  end

  describe "refuses" do
    test "an engine test request (rules and a list of claims)" do
      assert {:error, reason} = JsonClaim.parse(fixture("batches/batch_redundancy_extended.json"))
      assert reason =~ "not a claim"
    end

    test "a wrapper holding a list of claims" do
      assert {:error, reason} = JsonClaim.parse(~s({"claims": [{"claim_id": "C1"}]}))
      assert reason =~ "one claim per file"
    end

    test "a bare list" do
      assert {:error, reason} = JsonClaim.parse(~s([{"claim_id": "C1"}]))
      assert reason =~ "one claim per file"
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
