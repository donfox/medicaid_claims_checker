defmodule X12FraudWebWeb.Components.RuleComponents do
  use Phoenix.Component

  attr(:level, :string, required: true)

  def risk_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-3 py-1 rounded-full text-sm font-semibold",
      risk_color(@level)
    ]}>
      <%= @level %>
    </span>
    """
  end

  slot(:inner_block, required: true)

  def label(assigns) do
    ~H"""
    <label class="block text-sm font-semibold leading-6 text-gray-900">
      <%= render_slot(@inner_block) %>
    </label>
    """
  end

  defp risk_color("LowRisk"), do: "bg-green-100 text-green-800"
  defp risk_color("MediumRisk"), do: "bg-yellow-100 text-yellow-800"
  defp risk_color("HighRisk"), do: "bg-orange-100 text-orange-800"
  defp risk_color("CriticalRisk"), do: "bg-red-100 text-red-800"
  defp risk_color(_), do: "bg-gray-100 text-gray-800"
end
