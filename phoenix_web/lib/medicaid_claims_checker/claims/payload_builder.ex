defmodule MedicaidClaimsChecker.Claims.PayloadBuilder do
  @moduledoc """
  Builds the JSON request body for the engine's `/api/batch-evaluate`:
  the rule text and the claims, the only two fields that endpoint reads
  (`BatchEvaluateRequest` in haskell_engine/app/Routes.hs).
  `Claims.Evaluator` uses it.
  """

  @doc "The `/api/batch-evaluate` body for `rules_text` and a list of claims."
  def build_batch_evaluate_payload(rules_text, claims) when is_list(claims) do
    %{rulesText: String.replace(rules_text, "\r\n", "\n"), claims: claims}
  end
end
