defmodule MedicaidClaimsCheckerWeb.FetchConfigController do
  use MedicaidClaimsCheckerWeb, :controller

  alias MedicaidClaimsChecker.Ingestion

  def index(conn, _params) do
    sources = Ingestion.list_enabled_config()
    render(conn, :index, sources: sources)
  end
end
