defmodule MedicaidClaimsCheckerWeb.DevDashboard.BackToAdminPage do
  # Copyright (c) 2024-2026 Don Fox. All rights reserved.

  @moduledoc """
  A "← Back to Admin" item in the LiveDashboard (system monitor) menu.

  LiveDashboard draws its own page without the app's navigation, so this
  page gives it a way out: opening it sends the browser straight to the
  Admin page. Added in the router with `additional_pages`.
  """
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_session, _capabilities), do: {:ok, "← Back to Admin"}

  # Menu items open with a fresh mount, so this runs on every click.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, Phoenix.LiveView.redirect(socket, to: "/admin")}
  end

  @impl true
  def render(assigns), do: ~H""
end
