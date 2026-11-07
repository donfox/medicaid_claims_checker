defmodule MedicaidClaimsCheckerWeb.AdminLive do
  use MedicaidClaimsCheckerWeb, :live_view

  alias MedicaidClaimsChecker.Accounts
  alias MedicaidClaimsCheckerWeb.AdminLive.NppesPanel

  on_mount {MedicaidClaimsCheckerWeb.UserAuth, :require_admin}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:registration_open, Accounts.registration_open?())
     |> assign(:users, Accounts.list_users())
     |> assign(:password_link, nil)
     |> NppesPanel.assign_defaults()}
  end

  def handle_info(message, socket) do
    if NppesPanel.message?(message),
      do: NppesPanel.handle_info(message, socket),
      else: {:noreply, socket}
  end

  @nppes_events NppesPanel.events()

  def handle_event(event, params, socket) when event in @nppes_events do
    case assert_admin(socket) do
      :ok -> NppesPanel.handle_event(event, params, socket)
      :error -> {:noreply, put_flash(socket, :error, "Invalid request.")}
    end
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

  # For accounts made before password registration, which have no password,
  # and for users who have forgotten theirs. The app sends no email, so the
  # link is shown here for the admin to give the user.
  def handle_event("create_password_link", %{"id" => id}, socket) do
    with :ok <- assert_admin(socket),
         {user_id, ""} <- Integer.parse(id) do
      user = Accounts.get_user!(user_id)

      {:ok, link} = Accounts.create_password_setup_link(user, &url(~p"/users/set-password/#{&1}"))
      {:noreply, assign(socket, :password_link, %{email: user.email, url: link})}
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
    <div class="px-4 py-6 sm:px-6 sm:py-8 lg:px-8 xl:px-28 xl:py-10">
      <div class="mx-auto max-w-7xl space-y-8">
        <.header>Admin Settings</.header>

        <div
          :if={Phoenix.Flash.get(@flash, :error)}
          role="alert"
          class="p-4 bg-red-100 border border-red-300 rounded-lg"
        >
          <p class="text-sm text-red-900 font-semibold">{Phoenix.Flash.get(@flash, :error)}</p>
        </div>

        <div
          :if={Phoenix.Flash.get(@flash, :info)}
          role="alert"
          aria-live="polite"
          class="p-4 bg-blue-100 border border-blue-300 rounded-lg"
        >
          <p class="text-sm text-blue-900">{Phoenix.Flash.get(@flash, :info)}</p>
        </div>

        <div
          :if={@password_link}
          id="password-link"
          role="alert"
          class="p-4 bg-blue-100 border border-blue-300 rounded-lg space-y-2"
        >
          <p class="text-sm text-blue-900">
            Password link for <span class="font-semibold">{@password_link.email}</span>.
            Give it to them; it works once and expires in {Accounts.UserToken.password_setup_validity_in_days()} days.
          </p>
          <input
            type="text"
            readonly
            value={@password_link.url}
            class="w-full rounded border border-blue-300 bg-white px-2 py-1 font-mono text-sm"
          />
        </div>

        <%!-- Registration toggle --%>
        <div>
          <h2 class="text-lg font-semibold mb-3">System</h2>
          <div class="flex items-center justify-between rounded border p-4">
            <div>
              <p class="font-semibold">User Registration</p>
              <p class="text-sm text-gray-600">Allow new users to create accounts</p>
            </div>
            <button
              phx-click="toggle_registration"
              class={"btn #{if @registration_open, do: "btn-success", else: "btn-error"}"}
            >
              {if @registration_open, do: "Open — click to close", else: "Closed — click to open"}
            </button>
          </div>
        </div>

        <NppesPanel.panel
          nppes_config={@nppes_config}
          nppes_refreshing={@nppes_refreshing}
          nppes_provider_count={@nppes_provider_count}
          nppes_form_error={@nppes_form_error}
          nppes_rows_imported={@nppes_rows_imported}
          nppes_elapsed_display={@nppes_elapsed_display}
        />

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
                  <td class="whitespace-nowrap">{user.first_name} {user.last_name}</td>
                  <td class="font-mono text-sm">{user.email}</td>
                  <td class="text-sm text-gray-600 whitespace-nowrap">
                    {Calendar.strftime(user.inserted_at, "%b %d, %Y")}
                  </td>
                  <td>
                    <span class={"badge #{if user.active, do: "badge-success", else: "badge-error"}"}>
                      {if user.active, do: "Active", else: "Inactive"}
                    </span>
                    <span :if={is_nil(user.hashed_password)} class="badge badge-warning badge-outline">
                      No password
                    </span>
                  </td>
                  <td>
                    <span class={"badge #{if user.is_admin, do: "badge-warning", else: "badge-ghost"}"}>
                      {if user.is_admin, do: "Admin", else: "User"}
                    </span>
                  </td>
                  <td class="flex flex-wrap gap-2 justify-end">
                    <button
                      id={"create-password-link-#{user.id}"}
                      phx-click="create_password_link"
                      phx-value-id={user.id}
                      class="btn btn-sm btn-primary btn-soft"
                      disabled={!user.active}
                      title={if !user.active, do: "Activate the account first"}
                    >
                      Create password link
                    </button>
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
    </div>
    """
  end
end
