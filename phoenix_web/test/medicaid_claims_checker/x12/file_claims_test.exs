defmodule MedicaidClaimsChecker.X12.FileClaimsTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.Fingerprint
  alias MedicaidClaimsChecker.MockData
  alias MedicaidClaimsChecker.X12.{FileClaims, SegmentMapper}

  defp claims_of(rel), do: FileClaims.claims(Path.basename(rel), MockData.read!(rel))

  test "a one-claim file gives one claim named after the file, tagged with its source" do
    rel = "x12_files/837p_professional/clean_office_visit.x12"
    assert {[entry], []} = claims_of(rel)

    assert entry["filename"] == "clean_office_visit.json"
    assert SegmentMapper.normalize(entry["claim"])["claim_id"] == "CLEAN001"

    assert entry["source_file"] == %{
             "filename" => "clean_office_visit.x12",
             "sha256" => Fingerprint.file(MockData.read!(rel))
           }
  end

  test "several claims in one transaction set are named by claim ID" do
    assert {claims, []} = claims_of("x12_files/three_claims.x12")

    assert Enum.map(claims, & &1["filename"]) ==
             ~w(three_claims_MULTI01.json three_claims_MULTI02.json three_claims_MULTI03.json)
  end

  test "every transaction set in a file is read" do
    assert {claims, []} = claims_of("x12_files/two_transaction_sets.x12")
    assert length(claims) == 4
    assert claims |> Enum.map(& &1["source_file"]["filename"]) |> Enum.uniq() == ["two_transaction_sets.x12"]
  end

  test "a file that can't be read is a problem naming it, with no claims" do
    for rel <- [
          "x12_files/broken_envelope_or_file/truncated.x12",
          "x12_files/edi_extension/not_x12.edi"
        ] do
      assert {[], [%{"filename" => filename, "reason" => reason}]} = claims_of(rel)
      assert filename == Path.basename(rel)
      assert is_binary(reason) and reason != ""
    end
  end
end
