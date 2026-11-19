defmodule MedicaidClaimsChecker.Claims.PayloadBuilderTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Claims.PayloadBuilder

  test "the batch body holds only the rule text and the claims, as sent" do
    claims = [%{"claim_id" => "c1", "service_lines" => [%{"procedure_code" => "99213"}]}]
    rules = "RULE r \"ENDRULE in a message\" WHEN TRUE THEN RISK_SCORE 10;"

    payload = PayloadBuilder.build_batch_evaluate_payload(rules, claims)

    assert payload == %{rulesText: rules, claims: claims}

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
end
