defmodule MedicaidClaimsCheckerWeb.Router do
  use MedicaidClaimsCheckerWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MedicaidClaimsCheckerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", MedicaidClaimsCheckerWeb do
    pipe_through(:browser)

    live("/", FetchSourceLive.Index, :index)
    live("/rules", RuleLive.Index, :index)
  end

  # API routes
  scope "/api", MedicaidClaimsCheckerWeb do
    pipe_through :api
    get "/health", HealthController, :health
    post "/x12-batch-ingest", X12BatchIngestController, :create
    get "/x12-batch-ingest/:batch_id", X12BatchIngestController, :show
    get "/fetch-config", FetchConfigController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:medicaid_claims_checker, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: MedicaidClaimsCheckerWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
