defmodule X12FraudWeb.Application do
  # Copyright (c) 2024-2026 Don Fox. All rights reserved.

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      X12FraudWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:x12_fraud_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: X12FraudWeb.PubSub},
      X12FraudWeb.Repo,
      # Start to serve requests, typically the last entry
      X12FraudWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: X12FraudWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    X12FraudWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
