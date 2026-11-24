defmodule MedicaidClaimsChecker.Claims.FingerprintTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.Fingerprint
  alias MedicaidClaimsChecker.MockData
  alias MedicaidClaimsChecker.X12.{Converter, SegmentMapper}

  @claim %{
    "claim_id" => "CLM-1",
    "transaction_type" => "837I",
    "billing_provider" => %{"npi" => "1003005000"},
    "subscriber" => %{"member_id" => "MCD1", "middle_name" => nil},
    "patient" => %{"date_of_birth" => "19850315"},
    "financial" => %{"claim_amount" => 900.0},
    "claim_details" => %{"frequency_code" => "1", "facility_type_code" => "13"},
    "diagnosis_codes" => [%{"code" => "Z0000", "qualifier" => "ABK"}],
    "service_lines" => [
      %{
        "line_number" => 1,
        "revenue_code" => "0450",
        "procedure_code" => "99284",
        "charge_amount" => "900.00",
        "units" => "1",
        "date_of_service" => "20260911"
      }
    ],
    "interchange" => %{"control_number" => "000000001"}
  }

  defp same?(changed), do: Fingerprint.claim(changed) == Fingerprint.claim(@claim)

  test "a new envelope doesn't change the fingerprint" do
    assert same?(put_in(@claim, ["interchange", "control_number"], "000000002"))
  end

  test "blanks and fields a later translator adds don't change it" do
    changed =
      @claim
      |> put_in(["subscriber", "middle_name"], "")
      |> put_in(["claim_details", "statement_from_date"], nil)
      |> Map.put("other_codes", [])
      |> Map.put("a_field_added_later", "value")

    assert same?(changed)
  end

  test "the same amount written differently doesn't change it" do
    assert same?(put_in(@claim, ["financial", "claim_amount"], "900.00"))

    [line] = @claim["service_lines"]
    assert same?(Map.put(@claim, "service_lines", [%{line | "charge_amount" => 900, "units" => 1.0}]))
  end

  test "a change to what was billed changes it" do
    [line] = @claim["service_lines"]

    for changed <- [
          Map.put(@claim, "claim_id", "CLM-2"),
          put_in(@claim, ["claim_details", "frequency_code"], "7"),
          put_in(@claim, ["subscriber", "member_id"], "MCD2"),
          put_in(@claim, ["billing_provider", "npi"], "1003000118"),
          put_in(@claim, ["financial", "claim_amount"], 901.0),
          Map.put(@claim, "diagnosis_codes", [%{"code" => "J069", "qualifier" => "ABK"}]),
          Map.put(@claim, "other_codes", [%{"code" => "01", "qualifier" => "BG"}]),
          Map.put(@claim, "service_lines", [%{line | "procedure_code" => "99223"}]),
          Map.put(@claim, "service_lines", [%{line | "date_of_service" => "20260912"}]),
          Map.put(@claim, "service_lines", [Map.put(line, "modifiers", ["25"])])
        ] do
      refute same?(changed), "not detected: #{inspect(changed)}"
    end
  end

  test "modifiers count by code and order" do
    [line] = @claim["service_lines"]
    with_mods = fn mods -> Map.put(@claim, "service_lines", [Map.put(line, "modifiers", mods)]) end

    assert same?(with_mods.([]))

    assert Fingerprint.claim(with_mods.([%{"code" => "25"}])) ==
             Fingerprint.claim(with_mods.([%{"code" => "25", "description" => "Separate visit"}]))

    assert Fingerprint.claim(with_mods.([%{"code" => "25"}, %{"code" => "59"}])) !=
             Fingerprint.claim(with_mods.([%{"code" => "59"}, %{"code" => "25"}]))
  end

  describe "translated X12 claims" do
    defp translated(file, from \\ "", to \\ "") do
      x12 = MockData.read!(file)
      x12 = if from == "", do: x12, else: String.replace(x12, from, to)
      {:ok, flat} = Converter.convert_content(x12)
      {:ok, claim} = SegmentMapper.map_from_json(flat)
      SegmentMapper.normalize(claim)
    end

    @professional "x12_files/837p_professional/clean_office_visit.x12"
    @rendering "nppes_provider_checks/deactivated_rendering_provider/rendering_npi_deactivated.x12"
    @dental "x12_files/837d_dental/dental.x12"
    @institutional "x12_files/837i_institutional/institutional.x12"

    test "have the same fingerprint as their stored copy" do
      for file <- [@professional, @rendering, @dental, @institutional] do
        claim = translated(file)
        stored = claim |> Jason.encode!() |> Jason.decode!()
        assert Fingerprint.claim(claim) == Fingerprint.claim(stored), file
      end
    end

    test "differ when an identifying section differs" do
      for {file, from, to} <- [
            {@professional, "HI*ABK:Z0000", "HI*ABK:J069"},
            {@professional, "MCD000000001", "MCD000000999"},
            {@institutional, "HI*ABK:Z0000", "HI*ABK:Z0000*BG:01"},
            {@rendering, "NM1*82*1*GARCIA*MARIA****XX*1003002304", "NM1*82*1*GARCIA*MARIA****XX*1003000118"},
            {@dental, "TOO*JP*19", "TOO*JP*20"}
          ] do
        assert String.contains?(MockData.read!(file), from), "fixture lacks #{from}"
        assert Fingerprint.claim(translated(file)) != Fingerprint.claim(translated(file, from, to)),
               "not detected: #{from} -> #{to}"
      end
    end
  end

  test "claims without an ID are told apart by their contents" do
    one = %{"notes" => "first"}
    two = %{"notes" => "second"}
    assert Fingerprint.claim(one) != Fingerprint.claim(two)
  end

  test "an unexpected shape doesn't raise" do
    assert is_binary(
             Fingerprint.claim(%{
               "claim_id" => "CLM-1",
               "provider" => "text",
               "claim_details" => [],
               "diagnosis_codes" => ["J069"],
               "service_lines" => ["text"]
             })
           )
  end
end
