defmodule MedicaidClaimsCheckerWeb.AdminLive do
  use MedicaidClaimsCheckerWeb, :live_view

  alias MedicaidClaimsChecker.Accounts

  on_mount {MedicaidClaimsCheckerWeb.UserAuth, :require_admin}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:registration_open, Accounts.registration_open?())
     |> assign(:users, Accounts.list_users())}
  end

  def handle_event("toggle_registration", _params, socket) do
    with :ok <- assert_admin(socket) do
      new_state = !socket.assigns.registration_open
      {:ok, _} = Accounts.set_registration_open(new_state)
      {:noreply, assign(socket, :registration_open, new_state)}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    with :ok <- assert_admin(socket),
         {user_id, ""} <- Integer.parse(id) do
      current_user = socket.assigns.current_user
      user = Accounts.get_user!(user_id)

      if user.id == current_user.id do
        {:noreply, put_flash(socket, :error, "You cannot deactivate your own account.")}
      else
        new_state = !user.active
        {:ok, _} = Accounts.set_user_active(user, new_state)
        {:noreply, assign(socket, :users, Accounts.list_users())}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid request.")}
    end
  end

  def handle_event("toggle_admin", %{"id" => id}, socket) do
    with :ok <- assert_admin(socket),
         {user_id, ""} <- Integer.parse(id) do
      current_user = socket.assigns.current_user
      user = Accounts.get_user!(user_id)

      if user.id == current_user.id do
        {:noreply, put_flash(socket, :error, "You cannot change your own admin status.")}
      else
        new_state = !user.is_admin
        {:ok, _} = Accounts.set_user_admin(user, new_state)
        {:noreply, assign(socket, :users, Accounts.list_users())}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid request.")}
    end
  end

  defp assert_admin(socket) do
    user = socket.assigns[:current_user]
    if user && user.is_admin, do: :ok, else: :error
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-4xl space-y-8">
      <.header>Admin Settings</.header>

      <%!-- Registration toggle --%>
      <div>
        <h2 class="text-lg font-semibold mb-3">System</h2>
        <div class="flex items-center justify-between rounded border p-4">
          <div>
            <p class="font-semibold">User Registration</p>
            <p class="text-sm text-gray-500">Allow new users to create accounts</p>
          </div>
          <button
            phx-click="toggle_registration"
            class={"btn #{if @registration_open, do: "btn-success", else: "btn-error"}"}
          >
            <%= if @registration_open, do: "Open — click to close", else: "Closed — click to open" %>
          </button>
        </div>
      </div>

      <%!-- User management table --%>
      <div>
        <h2 class="text-lg font-semibold mb-3">Users</h2>
        <div class="overflow-x-auto rounded border">
          <table class="table w-full">
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
                <th>Joined</th>
                <th>Status</th>
                <th>Role</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={user <- @users}>
                <td>{user.first_name} {user.last_name}</td>
                <td class="font-mono text-sm">{user.email}</td>
                <td class="text-sm text-gray-500">
                  {Calendar.strftime(user.inserted_at, "%b %d, %Y")}
                </td>
                <td>
                  <span class={"badge #{if user.active, do: "badge-success", else: "badge-error"}"}>
                    {if user.active, do: "Active", else: "Inactive"}
                  </span>
                </td>
                <td>
                  <span class={"badge #{if user.is_admin, do: "badge-warning", else: "badge-ghost"}"}>
                    {if user.is_admin, do: "Admin", else: "User"}
                  </span>
                </td>
                <td class="flex gap-2 justify-end">
                  <button
                    phx-click="toggle_active"
                    phx-value-id={user.id}
                    class={"btn btn-sm #{if user.active, do: "btn-error btn-soft", else: "btn-success btn-soft"}"}
                    disabled={user.id == @current_user.id}
                  >
                    {if user.active, do: "Deactivate", else: "Activate"}
                  </button>
                  <button
                    phx-click="toggle_admin"
                    phx-value-id={user.id}
                    class="btn btn-sm btn-soft"
                    disabled={user.id == @current_user.id}
                  >
                    {if user.is_admin, do: "Remove admin", else: "Make admin"}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
