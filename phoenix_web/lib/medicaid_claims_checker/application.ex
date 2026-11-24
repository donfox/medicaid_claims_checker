defmodule MedicaidClaimsChecker.Application do
  # Copyright (c) 2024-2026 Don Fox. All rights reserved.

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MedicaidClaimsChecker.Vault,
      MedicaidClaimsCheckerWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:medicaid_claims_checker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MedicaidClaimsChecker.PubSub},
      MedicaidClaimsChecker.Repo,
      {Oban, Application.fetch_env!(:medicaid_claims_checker, Oban)},
      {Task.Supervisor, name: MedicaidClaimsChecker.TaskSupervisor},
      MedicaidClaimsChecker.Scheduler
    ] ++ config_poller() ++ [
      MedicaidClaimsChecker.Nppes.RefreshWorker,
      # Start to serve requests, typically the last entry
      MedicaidClaimsCheckerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MedicaidClaimsChecker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The poller reads the database outside any test's sandbox, so the test
  # config turns it off (config :medicaid_claims_checker, :config_poller).
  defp config_poller do
    if Application.get_env(:medicaid_claims_checker, :config_poller, [])
       |> Keyword.get(:enabled, true),
       do: [MedicaidClaimsChecker.Ingestion.ConfigPoller],
       else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MedicaidClaimsCheckerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
