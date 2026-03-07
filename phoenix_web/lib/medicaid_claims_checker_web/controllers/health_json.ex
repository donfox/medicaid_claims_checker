defmodule MedicaidClaimsCheckerWeb.HealthJSON do
  @moduledoc """
  JSON responses for the health check endpoint.
  """

  @doc """
  Renders the health status.
  """
  def health(_assigns) do
    %{
      status: "healthy",
      service: "phoenix_frontend",
      port: 4000,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
