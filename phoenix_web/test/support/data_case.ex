defmodule MedicaidClaimsChecker.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MedicaidClaimsChecker.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MedicaidClaimsChecker.DataCase
    end
  end

  setup tags do
    MedicaidClaimsChecker.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) and
         function_exported?(Ecto.Adapters.SQL.Sandbox, :start_owner!, 2) and
         function_exported?(Ecto.Adapters.SQL.Sandbox, :stop_owner, 1) do
      pid =
        apply(Ecto.Adapters.SQL.Sandbox, :start_owner!, [
          MedicaidClaimsChecker.Repo,
          [shared: not tags[:async]]
        ])

      on_exit(fn -> apply(Ecto.Adapters.SQL.Sandbox, :stop_owner, [pid]) end)
    else
      :ok
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
