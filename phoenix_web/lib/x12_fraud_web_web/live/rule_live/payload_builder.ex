defmodule X12FraudWebWeb.RuleLive.PayloadBuilder do
  @moduledoc false

  def build_evaluate_payload(rules_text, claim_document, opts \\ %{}) do
    contract_metadata(opts)
    |> Map.merge(%{
      rulesText: normalize_dsl_text(rules_text),
      document: claim_document
    })
  end

  def build_batch_evaluate_payload(rules_text, claims, opts \\ %{}) do
    request_id =
      Map.get(opts, :request_id, "req_" <> Integer.to_string(System.system_time(:millisecond)))

    build_evaluate_payload(
      rules_text,
      %{},
      Map.merge(opts, %{request_id: request_id, claim_id: "batch_" <> request_id})
    )
    |> Map.delete(:document)
    |> Map.put(:claims, claims)
  end

  def contract_metadata(opts \\ %{}) do
    request_id =
      Map.get(opts, :request_id, "req_" <> Integer.to_string(System.system_time(:millisecond)))

    %{
      contract_version: "1.0",
      request_id: request_id,
      claim_id: Map.get(opts, :claim_id, "claim_" <> request_id),
      tenant_id: Map.get(opts, :tenant_id, default_tenant_id()),
      context: Map.get(opts, :context, %{})
    }
  end

  def normalize_dsl_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("ENDRULE", "END RULE")
  end

  defp default_tenant_id do
    System.get_env("TENANT_ID") || "default_tenant"
  end
end
