defmodule MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder do
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

    enriched_claims = Enum.map(claims, &flatten_first_service_line/1)

    build_evaluate_payload(
      rules_text,
      %{},
      Map.merge(opts, %{request_id: request_id, claim_id: "batch_" <> request_id})
    )
    |> Map.delete(:document)
    |> Map.put(:claims, enriched_claims)
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

  # Promotes first service line fields to `claim.first_service_line.*` so the
  # Haskell rule engine (which doesn't support array indexing) can reference them.
  defp flatten_first_service_line(%{"claim" => %{"service_lines" => [first | _]}} = doc) do
    put_in(doc, ["claim", "first_service_line"], first)
  end

  defp flatten_first_service_line(doc), do: doc

  defp default_tenant_id do
    System.get_env("TENANT_ID") || "default_tenant"
  end
end
