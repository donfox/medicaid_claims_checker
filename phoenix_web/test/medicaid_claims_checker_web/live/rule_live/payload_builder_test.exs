defmodule MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilderTest do
  use ExUnit.Case, async: false

  alias MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder

  test "build_batch_evaluate_payload includes strict contract fields" do
    payload =
      PayloadBuilder.build_batch_evaluate_payload(
        "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
        [%{"amount" => 100}],
        %{
          request_id: "req_123",
          tenant_id: "payer_a",
          context: %{region: "TX"}
        }
      )

    assert payload.contract_version == "1.0"
    assert payload.request_id == "req_123"
    assert payload.claim_id == "batch_req_123"
    assert payload.tenant_id == "payer_a"
    assert payload.context == %{region: "TX"}
    assert payload.rulesText == "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;"
    assert payload.claims == [%{"amount" => 100}]
    refute Map.has_key?(payload, :document)
  end

  test "build_evaluate_payload normalizes DSL text" do
    payload =
      PayloadBuilder.build_evaluate_payload(
        "RULE r \"d\"\r\nWHEN TRUE\r\nTHEN RISK_SCORE 10\r\nENDRULE",
        %{"amount" => 42},
        %{request_id: "req_1", claim_id: "claim_1", tenant_id: "payer_a"}
      )

    assert payload.contract_version == "1.0"
    assert payload.request_id == "req_1"
    assert payload.claim_id == "claim_1"
    assert payload.tenant_id == "payer_a"
    assert payload.document == %{"amount" => 42}
    assert payload.rulesText == "RULE r \"d\"\nWHEN TRUE\nTHEN RISK_SCORE 10\nEND RULE"
  end

  test "batch payload JSON body carries required contract keys" do
    payload =
      PayloadBuilder.build_batch_evaluate_payload(
        "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
        [%{"claim_id" => "c1"}],
        %{request_id: "req_abc", tenant_id: "payer_a"}
      )

    {:ok, decoded} = payload |> Jason.encode!() |> Jason.decode()

    assert decoded["contract_version"] == "1.0"
    assert decoded["request_id"] == "req_abc"
    assert decoded["claim_id"] == "batch_req_abc"
    assert decoded["tenant_id"] == "payer_a"
    assert is_list(decoded["claims"])
    assert decoded["rulesText"] == "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;"
  end

  test "defaults tenant_id to default_tenant when not provided" do
    prev = System.get_env("TENANT_ID")
    System.delete_env("TENANT_ID")

    try do
      payload =
        PayloadBuilder.build_batch_evaluate_payload(
          "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
          [%{"claim_id" => "c1"}],
          %{request_id: "req_no_tenant"}
        )

      assert payload.tenant_id == "default_tenant"
    after
      if prev do
        System.put_env("TENANT_ID", prev)
      else
        System.delete_env("TENANT_ID")
      end
    end
  end

  test "uses TENANT_ID env value when tenant_id option is not provided" do
    prev = System.get_env("TENANT_ID")
    System.put_env("TENANT_ID", "payer_from_env")

    try do
      payload =
        PayloadBuilder.build_batch_evaluate_payload(
          "RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;",
          [%{"claim_id" => "c1"}],
          %{request_id: "req_env_tenant"}
        )

      assert payload.tenant_id == "payer_from_env"
    after
      if prev do
        System.put_env("TENANT_ID", prev)
      else
        System.delete_env("TENANT_ID")
      end
    end
  end
end
