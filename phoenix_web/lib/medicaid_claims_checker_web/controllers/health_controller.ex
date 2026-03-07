defmodule MedicaidClaimsCheckerWeb.HealthController do
  use MedicaidClaimsCheckerWeb, :controller

  @doc """
  Health check endpoint for Phoenix frontend.
  Returns JSON indicating the service is running.
  """
  def health(conn, _params) do
    render(conn, :health)
  end
end
