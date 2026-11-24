defmodule MedicaidClaimsChecker.Claims.FingerprintTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.Fingerprint

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
