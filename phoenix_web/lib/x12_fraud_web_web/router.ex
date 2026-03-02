defmodule X12FraudWebWeb.Router do
  use X12FraudWebWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {X12FraudWebWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", X12FraudWebWeb do
    pipe_through(:browser)

    live("/", RuleLive.Index, :index)
    live("/rules", RuleLive.Index, :index)
    live("/catalogue", RuleCatalogueLive.Index, :index)
  end

  # API routes
  scope "/api", X12FraudWebWeb do
    pipe_through :api
    get "/health", HealthController, :health
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:x12_fraud_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: X12FraudWebWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
