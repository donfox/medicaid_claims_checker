defmodule MedicaidClaimsChecker.Claims.PayloadBuilder do
  @moduledoc """
  Builds the JSON request body for the engine's `/api/batch-evaluate`:
  the rule text and the claims, the only two fields that endpoint reads
  (`BatchEvaluateRequest` in haskell_engine/app/Routes.hs).
  `Claims.Evaluator` uses it.

  Every claim, X12 or JSON, passes through here on its way to the engine,
  so values worked out from the claim are added here:

    * `claim_totals.service_line_total` — the sum of the service lines'
      `charge_amount`, added in exact decimal so a claim that balances to
      the cent compares equal to its `financial.claim_amount`. Empty (nil)
      when the claim has no lines, or any line's charge is missing or not a
      number, so a rule using it is "not checked" rather than wrong. Always
      recomputed: a value sent in the claim itself is replaced.
  """

  @doc "The `/api/batch-evaluate` body for `rules_text` and a list of claims."
  def build_batch_evaluate_payload(rules_text, claims) when is_list(claims) do
    %{
      rulesText: String.replace(rules_text, "\r\n", "\n"),
      claims: Enum.map(claims, &add_derived_fields/1)
    }
  end

  @doc "Adds the worked-out fields listed in the moduledoc to one claim."
  def add_derived_fields(%{} = claim) do
    totals =
      case Map.get(claim, "claim_totals") do
        %{} = t -> t
        _ -> %{}
      end

    total = service_line_total(Map.get(claim, "service_lines"))
    Map.put(claim, "claim_totals", Map.put(totals, "service_line_total", total))
  end

  def add_derived_fields(other), do: other

  defp service_line_total([_ | _] = lines) do
    lines
    |> Enum.reduce_while(Decimal.new(0), fn line, sum ->
      case line |> charge() |> to_decimal() do
        nil -> {:halt, nil}
        amount -> {:cont, Decimal.add(sum, amount)}
      end
    end)
    |> case do
      nil -> nil
      sum -> Decimal.to_float(sum)
    end
  end

  defp service_line_total(_), do: nil

  defp charge(%{} = line), do: Map.get(line, "charge_amount")
  defp charge(_), do: nil

  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, ""} -> if Decimal.inf?(d) or Decimal.nan?(d), do: nil, else: d
      _ -> nil
    end
  end

  defp to_decimal(_), do: nil
end
