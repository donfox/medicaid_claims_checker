defmodule X12FraudWebWeb.RuleLive.Index do
  use X12FraudWebWeb, :live_view
  import X12FraudWebWeb.Components.RuleComponents

  @impl true
  def mount(_params, _session, socket) do
    default_rule = get_default_rule()

    # Validate the default rule on mount
    {parsed_rule, parse_error} =
      case parse_rule(default_rule) do
        {:ok, parsed} -> {parsed, nil}
        {:error, error} -> {nil, error}
      end

    {:ok,
     socket
     |> assign(:rule_text, default_rule)
     |> assign(:parsed_rule, parsed_rule)
     |> assign(:parse_error, parse_error)
     |> assign(:evaluation_result, nil)
     |> assign(:compilation_result, nil)
     |> assign(:claim_json_text, "")
     |> assign(:claim_parse_error, nil)
     |> assign(:x12_document, %{})
     |> assign(:claim_form_version, 0)
     |> assign(:rule_form_version, 0)}
  end

  @impl true
  def handle_event("validate_rule", %{"rule" => %{"text" => text}}, socket) do
    case parse_rule(text) do
      {:ok, parsed} ->
        {:noreply,
         socket
         |> assign(:rule_text, text)
         |> assign(:parsed_rule, parsed)
         |> assign(:parse_error, nil)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:rule_text, text)
         |> assign(:parsed_rule, nil)
         |> assign(:parse_error, error)}
    end
  end

  @impl true
  def handle_event("evaluate_rule", %{"rule" => %{"text" => text}}, socket) do
    # Update rule_text from form and evaluate
    IO.inspect({:handle_evaluate_event, "with_text", text})

    case evaluate_rule(text, socket.assigns.x12_document) do
      {:ok, result} ->
        IO.inspect({:evaluation_success, "assigning result"})

        {:noreply,
         socket
         |> assign(:rule_text, text)
         |> assign(:evaluation_result, result)
         |> clear_flash()}

      {:error, error} ->
        IO.inspect({:evaluation_error, error})

        {:noreply,
         socket
         |> assign(:rule_text, text)
         |> assign(:evaluation_result, nil)
         |> put_flash(:error, "Evaluation failed: #{error}")}
    end
  end

  @impl true
  def handle_event("evaluate_rule", _params, socket) do
    # Fallback: evaluate with current rule text and document
    IO.inspect({:handle_evaluate_event, "fallback"})

    case evaluate_rule(socket.assigns.rule_text, socket.assigns.x12_document) do
      {:ok, result} ->
        IO.inspect({:evaluation_success_fallback, "assigning result"})

        {:noreply,
         socket
         |> assign(:evaluation_result, result)
         |> clear_flash()}

      {:error, error} ->
        IO.inspect({:evaluation_error_fallback, error})

        {:noreply,
         socket
         |> assign(:evaluation_result, nil)
         |> put_flash(:error, "Evaluation failed: #{error}")}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:rule_text, "")
     |> assign(:parsed_rule, nil)
     |> assign(:parse_error, nil)
     |> assign(:evaluation_result, nil)
     |> update(:rule_form_version, &(&1 + 1))}
  end

  @impl true
  def handle_event("compile_rule", _params, socket) do
    case compile_rule(socket.assigns.rule_text) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:compilation_result, result)
         |> put_flash(:info, "Rule compiled successfully in #{Float.round(result["compilationTimeMs"] / 1, 1)}ms")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:compilation_result, %{"success" => false, "error" => error})
         |> put_flash(:error, "Compilation failed: #{error}")}
    end
  end

  @impl true
  def handle_event("update_claim", %{"claim" => %{"json" => json_text}}, socket) do
    process_claim_text(json_text, socket)
  end

  @impl true
  def handle_event("update_claim_text", %{"text" => json_text}, socket) do
    process_claim_text(json_text, socket)
  end

  @impl true
  def handle_event("clear_claim", _params, socket) do
    {:noreply,
     socket
     |> assign(:claim_json_text, "")
     |> assign(:x12_document, %{})
     |> assign(:claim_parse_error, nil)
     |> push_event("set_claim_text", %{text: ""})}
  end

  @impl true
  def handle_event("reset_claim", _params, socket) do
    sample_doc = get_sample_document()
    json_text = Jason.encode!(sample_doc, pretty: true)

    {:noreply,
     socket
     |> assign(:claim_json_text, json_text)
     |> assign(:x12_document, sample_doc)
     |> assign(:claim_parse_error, nil)
     |> assign(:evaluation_result, nil)
     |> push_event("set_claim_text", %{text: json_text})}
  end

  defp process_claim_text(json_text, socket) do
    case Jason.decode(json_text) do
      {:ok, document} ->
        desc = cond do
          is_map(document) -> "object with #{map_size(document)} keys"
          is_list(document) -> "array with #{length(document)} items"
          true -> "value"
        end
        IO.inspect({:claim_parsed_successfully, "document is #{desc}"})

        {:noreply,
         socket
         |> assign(:claim_json_text, json_text)
         |> assign(:x12_document, document)
         |> assign(:claim_parse_error, nil)}

      {:error, error} ->
        error_msg =
          case error do
            %Jason.DecodeError{} = e -> "JSON Parse Error at position #{e.position}: #{e.data}"
            _ -> "Invalid JSON: #{inspect(error)}"
          end

        IO.inspect({:claim_parse_error, error_msg})

        {:noreply,
         socket
         |> assign(:claim_json_text, json_text)
         |> assign(:claim_parse_error, error_msg)}
    end
  end

  defp compile_rule(rule_text) do
    case HTTPoison.post(
           "http://localhost:8080/api/compile-rule",
           Jason.encode!(%{ruleText: rule_text}),
           [{"Content-Type", "application/json"}],
           timeout: 60_000,
           recv_timeout: 60_000
         ) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"success" => true} = result} -> {:ok, result}
          {:ok, %{"success" => false, "error" => err}} -> {:error, err}
          {:ok, %{"error" => err}} -> {:error, err}
          _ -> {:error, "Unexpected response from compiler"}
        end

      {:ok, %{status_code: 400, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => err}} -> {:error, err}
          _ -> {:error, body}
        end

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp parse_rule(text) do
    # Call Haskell backend to parse rule
    case HTTPoison.post(
           "http://localhost:8080/api/parse-rule",
           Jason.encode!(%{ruleText: text}),
           [{"Content-Type", "application/json"}]
         ) do
      {:ok, %{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp evaluate_rule(rule_text, document) do
    # Call Haskell backend to evaluate rule - any valid JSON is accepted
    IO.inspect({:evaluating, rule_text, "document_size: #{byte_size(Jason.encode!(document))}"})
    do_evaluate_rule(rule_text, document)
  end

  defp do_evaluate_rule(rule_text, document) do
    case HTTPoison.post(
           "http://localhost:8080/api/evaluate",
           Jason.encode!(%{rulesText: rule_text, document: document}),
           [{"Content-Type", "application/json"}],
           timeout: 30000,
           recv_timeout: 30000
         ) do
      {:ok, %{status_code: 200, body: body}} ->
        IO.inspect({:backend_response, "status_code: 200", "body_size: #{byte_size(body)}"})

        case Jason.decode(body) do
          {:ok, %{"error" => error_msg}} ->
            IO.inspect({:backend_error, error_msg})
            {:error, error_msg}

          {:ok, result} ->
            IO.inspect({:backend_success, "result received"})
            {:ok, result}

          {:error, decode_error} ->
            IO.inspect({:decode_error, decode_error})
            {:error, "Invalid response from backend"}
        end

      {:ok, %{status_code: 400, body: body}} ->
        IO.inspect({:backend_validation_error, body})

        case Jason.decode(body) do
          {:ok, %{"error" => err}} -> {:error, err}
          _ -> {:error, body}
        end

      {:ok, response} ->
        IO.inspect({:backend_error_status, response.status_code, response.body})
        {:error, "Backend error (#{response.status_code}): #{response.body}"}

      {:error, error} ->
        IO.inspect({:http_error, inspect(error)})
        {:error, "HTTP Error: #{inspect(error)}"}
    end
  end

  defp get_default_rule do
    """
    RULE high_claim_amount
    DESCRIPTION "Flag claims with unusually high amounts"
    WHEN 2300.CLM.02 > 50000
    THEN FLAG_FRAUD "Claim amount exceeds $50,000 threshold"
    END
    """
  end

  defp get_sample_document do
    %{
      "docInterchanges" => [
        %{
          "intControlNumber" => "000000001",
          "intSender" => "SENDER123",
          "intReceiver" => "RECEIVER456",
          "intGroups" => [
            %{
              "fgControlNumber" => "1",
              "fgTransactions" => [
                %{
                  "txControlNumber" => "0001",
                  "txType" => "837",
                  "txLoops" => %{
                    "2300" => [
                      %{
                        "loopId" => "2300",
                        "loopSegments" => [
                          %{
                            "segmentId" => "CLM",
                            "segmentElements" => [
                              %{"elementValue" => "CLAIM001", "elementSubelements" => []},
                              %{"elementValue" => "75000.00", "elementSubelements" => []},
                              %{"elementValue" => "PENDING", "elementSubelements" => []}
                            ]
                          }
                        ],
                        "loopChildren" => []
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  end
end
