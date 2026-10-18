defmodule MedicaidClaimsChecker.X12.ClaimSplitterTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}

  # Raw X12 files from the generated suite (test/fixtures/x12_suite/generate.exs).
  @files "test/fixtures/x12_suite/files"

  defp read(rel), do: File.read!(Path.join(@files, rel))

  # The upload/fetch path: transaction sets, then claims, then conversion.
  defp claims(content) do
    with {:ok, sets} <- ClaimSplitter.split_transaction_sets(content) do
      (sets || [content])
      |> Enum.flat_map(fn set ->
        case ClaimSplitter.split_claims_to_x12(set) do
          {:ok, nil} -> [set]
          {:ok, parts} -> Enum.map(parts, & &1.x12_content)
        end
      end)
      |> Enum.map(fn x12 ->
        {:ok, flat} = Converter.convert_content(x12)
        {:ok, claim} = SegmentMapper.map_from_json(flat)
        claim
      end)
      |> then(&{:ok, &1})
    end
  end

  describe "check_envelope via split_transaction_sets/1" do
    test "accepts a well-formed file" do
      assert {:ok, nil} =
               ClaimSplitter.split_transaction_sets(read("single/01_clean_office_visit.x12"))
    end

    test "rejects a truncated file as an incomplete transmission" do
      assert {:error, "Incomplete transmission:" <> _} =
               ClaimSplitter.split_transaction_sets(read("errors/01_truncated_file.x12"))
    end

    test "rejects a wrong SE segment count" do
      assert {:error, "SE segment count is 27 but transaction set 0001 has 24 segments"} =
               ClaimSplitter.split_transaction_sets(read("errors/02_wrong_se_count.x12"))
    end

    test "rejects an IEA control number that differs from ISA13" do
      assert {:error,
              "Interchange control number mismatch: ISA13 is 000000101 but IEA02 is 000000999"} =
               ClaimSplitter.split_transaction_sets(read("errors/03_control_number_mismatch.x12"))
    end

    test "rejects a GE count that doesn't match the transaction sets" do
      content =
        String.replace(read("multi/02_two_transaction_sets.x12"), "GE*2*101~", "GE*1*101~")

      assert {:error, "GE says 1 transaction sets but the group has 2"} =
               ClaimSplitter.split_transaction_sets(content)
    end
  end

  describe "split_claims_to_x12/1" do
    test "a transaction set with no CLM is an error, not an empty claim" do
      content = read("errors/06_envelope_no_claims.x12")
      assert {:error, "No claims found" <> _} = ClaimSplitter.split_claims_to_x12(content)
    end

    test "two claims under one subscriber each keep their own lines" do
      assert {:ok, [first, second]} = claims(read("multi/03_two_claims_same_subscriber.x12"))

      assert first["claim_id"] == "SAMESUB01"
      assert Enum.map(first["service_lines"], & &1["charge_amount"]) == ["150.00"]
      assert second["claim_id"] == "SAMESUB02"
      assert Enum.map(second["service_lines"], & &1["charge_amount"]) == ["2.00"]

      for claim <- [first, second] do
        assert claim["billing_provider"]["npi"] == "1122334455"
        assert claim["patient"]["date_of_birth"] == "19850315"
      end
    end

    test "claims under different subscribers keep their own subscriber" do
      assert {:ok, claims} = claims(read("multi/01_three_claims.x12"))

      assert Enum.map(claims, &{&1["claim_id"], &1["patient"]["name"]["last"]}) ==
               [{"MULTI01", "ALPHA"}, {"MULTI02", "BRAVO"}, {"MULTI03", "CHARLIE"}]
    end

    test "each claim carries its own billing provider when a file has two" do
      content = read("multi/03_two_claims_same_subscriber.x12")

      # Give the second claim its own billing-provider (HL 20) and subscriber loop.
      [head, tail] = String.split(content, "CLM*SAMESUB02", parts: 2)

      second_provider =
        "HL*3**20*1~\nNM1*85*2*UNIVERSITY ORTHOPEDIC HOSPITAL*****XX*1654321987~\n" <>
          "HL*4*3*22*0~\nSBR*P*18*******MC~\nNM1*IL*1*SECOND*PAT****MI*MCD000000999~\n"

      content = head <> second_provider <> "CLM*SAMESUB02" <> tail
      {:ok, parts} = ClaimSplitter.split_claims_to_x12(content)

      npis =
        Enum.map(parts, fn %{x12_content: x12} ->
          {:ok, flat} = Converter.convert_content(x12)
          {:ok, claim} = SegmentMapper.map_from_json(flat)
          {claim["claim_id"], claim["billing_provider"]["npi"], claim["patient"]["name"]["last"]}
        end)

      assert npis == [
               {"SAMESUB01", "1122334455", "TESTPATIENT"},
               {"SAMESUB02", "1654321987", "SECOND"}
             ]
    end
  end

  describe "conversion details" do
    test "uses the file's sub-element separator (ISA16) for composites" do
      assert {:ok, [claim]} = claims(read("formats/05_alternate_delimiters.edi"))

      assert [%{"procedure_code" => "99285", "procedure_qualifier" => "HC"}] =
               claim["service_lines"]

      assert [%{code: "Z0000", qualifier: "ABK"}] = claim["diagnosis_codes"]
      assert claim["claim_details"]["place_of_service"] == "23"
    end

    test "keeps REF*G1 prior authorization" do
      assert {:ok, [claim]} = claims(read("single/23_with_prior_auth.x12"))
      assert claim["authorization"]["authorization_number"] == "PA20260001"

      assert {:ok, [claim]} = claims(read("single/22_no_prior_auth.x12"))
      assert claim["authorization"]["authorization_number"] == nil
    end

    test "keeps place of service on the claim and each service line" do
      assert {:ok, [claim]} = claims(read("single/24_weekend_office_visit.x12"))
      assert claim["claim_details"]["place_of_service"] == "11"
      assert [%{"place_of_service" => "11"}] = claim["service_lines"]
    end

    test "an absent billing NPI becomes nil, not an empty string" do
      assert {:ok, [claim]} = claims(read("single/25_missing_billing_npi.x12"))
      assert claim["provider"]["npi"] == nil
      assert claim["billing_provider"]["npi"] == nil
    end
  end
end
