defmodule X12FraudWeb.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias X12FraudWeb.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import X12FraudWeb.DataCase
    end
  end

  setup tags do
    X12FraudWeb.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) and
         function_exported?(Ecto.Adapters.SQL.Sandbox, :start_owner!, 2) and
         function_exported?(Ecto.Adapters.SQL.Sandbox, :stop_owner, 1) do
      pid =
        apply(Ecto.Adapters.SQL.Sandbox, :start_owner!, [X12FraudWeb.Repo, [shared: not tags[:async]]])

      on_exit(fn -> apply(Ecto.Adapters.SQL.Sandbox, :stop_owner, [pid]) end)
    else
      :ok
    end
  end
end
