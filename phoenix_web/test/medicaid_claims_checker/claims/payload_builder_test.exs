defmodule MedicaidClaimsChecker.Claims.PayloadBuilderTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.PayloadBuilder

  test "the batch body holds only the rule text and the claims" do
    claims = [%{"claim_id" => "c1", "service_lines" => [%{"procedure_code" => "99213"}]}]
    rules = "RULE r \"ENDRULE in a message\" WHEN TRUE THEN RISK_SCORE 10;"

    payload = PayloadBuilder.build_batch_evaluate_payload(rules, claims)

    assert Map.keys(payload) == [:claims, :rulesText]
    assert payload.rulesText == rules
    assert [%{"claim_id" => "c1", "service_lines" => [%{"procedure_code" => "99213"}]}] = payload.claims

    assert {:ok, %{"rulesText" => ^rules, "claims" => [_]}} =
             payload |> Jason.encode!() |> Jason.decode()
  end

  test "Windows line endings in the rule text become plain newlines" do
    payload =
      PayloadBuilder.build_batch_evaluate_payload(
        "RULE r \"d\"\r\nWHEN TRUE\r\nTHEN RISK_SCORE 10;",
        []
      )

    assert payload.rulesText == "RULE r \"d\"\nWHEN TRUE\nTHEN RISK_SCORE 10;"
  end

  describe "claim_totals.service_line_total" do
    defp total(lines, extra \\ %{}) do
      %{"claim_id" => "c1", "service_lines" => lines}
      |> Map.merge(extra)
      |> PayloadBuilder.add_derived_fields()
      |> get_in(["claim_totals", "service_line_total"])
    end

    defp line(charge), do: %{"charge_amount" => charge}

    test "adds up the line charges, whether text (X12) or numbers (JSON)" do
      assert total([line("150.00"), line("18.00")]) == 168.0
      assert total([line(150.0), line(18)]) == 168.0
      assert total([line(" 95.50 "), line(4.5)]) == 100.0
    end

    test "adds in exact decimal, so cents compare equal to the claim amount" do
      # As floats, 0.10 + 0.20 is 0.30000000000000004.
      assert total([line("0.10"), line("0.20")]) == 0.3
      assert total([line(0.1), line(0.2)]) == 0.3
      assert total(List.duplicate(line("33.33"), 3)) == 99.99
    end

    test "a negative line (a credit) counts against the total" do
      assert total([line("230.00"), line("-70.00")]) == 160.0
    end

    test "nil when there are no lines, or any charge is missing or not a number" do
      assert total([]) == nil
      assert total(nil) == nil
      assert total([line("150.00"), %{"procedure_code" => "99213"}]) == nil
      assert total([line("150.00"), line(nil)]) == nil
      assert total([line("150.00"), line("abc")]) == nil
      assert total([line("150.00"), line("12.5x")]) == nil
      assert total([line("NaN")]) == nil
      assert total([line("150.00"), "not a line"]) == nil
    end

    test "keeps the claim's other totals and replaces a total sent in the claim" do
      claim =
        PayloadBuilder.add_derived_fields(%{
          "service_lines" => [line("40.00")],
          "claim_totals" => %{"total_charges" => 40.0, "service_line_total" => 999}
        })

      assert claim["claim_totals"] == %{"total_charges" => 40.0, "service_line_total" => 40.0}
    end

    test "is added to every claim in the batch body" do
      payload =
        PayloadBuilder.build_batch_evaluate_payload("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 1;", [
          %{"claim_id" => "a", "service_lines" => [line("10.00")]},
          %{"claim_id" => "b", "claim_totals" => nil, "service_lines" => [line("5"), line("5")]}
        ])

      assert Enum.map(payload.claims, & &1["claim_totals"]["service_line_total"]) == [10.0, 10.0]
    end
  end
end
