defmodule MedicaidClaimsCheckerWeb.Router do
  use MedicaidClaimsCheckerWeb, :router

  import MedicaidClaimsCheckerWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MedicaidClaimsCheckerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope_for_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", MedicaidClaimsCheckerWeb do
    pipe_through([:browser, :require_authenticated_user])

    live("/", FetchSourceLive.Index, :index)
    live("/rules", RuleLive.Index, :index)
  end

  scope "/admin", MedicaidClaimsCheckerWeb do
    pipe_through([:browser, :require_authenticated_user, :require_admin])

    live("/", AdminLive, :index)
  end

  # API routes
  scope "/api", MedicaidClaimsCheckerWeb do
    pipe_through(:api)
    get("/health", HealthController, :health)
  end

  scope "/api", MedicaidClaimsCheckerWeb do
    pipe_through([:api, :require_rule_engine_secret])
    get("/fetch-config", FetchConfigController, :index)
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

  ## Authentication routes

  scope "/", MedicaidClaimsCheckerWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", MedicaidClaimsCheckerWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", MedicaidClaimsCheckerWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
