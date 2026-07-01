defmodule Data.Application do
  @moduledoc """
  OTP application entry point. Starts the top-level supervision tree —
  telemetry, the Ecto repo, the ExDatalog knowledge cache, PubSub, DNS
  clustering, and the Phoenix endpoint — when the `:data` application boots.

  TerminusDB is deliberately not started here: `TerminusDB.Config` is plain
  data with no connection process, so there's nothing to supervise, and
  provisioning it over HTTP at boot would make the app fail to start
  whenever TerminusDB is unreachable. See `Data.TerminusDB.Setup` and
  `mix terminus.setup` instead.
  """

  use Application

  @doc """
  Starts the supervision tree. Invoked automatically by the runtime; see
  `c:Application.start/2`.
  """
  @impl true
  def start(_type, _args) do
    children = [
      DataWeb.Telemetry,
      Data.Repo,
      Data.Reasoning.Store,
      {DNSCluster, query: Application.get_env(:data, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Data.PubSub},
      # Start a worker by calling: Data.Worker.start_link(arg)
      # {Data.Worker, arg},
      # Start to serve requests, typically the last entry
      DataWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Data.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Tells Phoenix to update the endpoint configuration whenever the
  application is updated (e.g. via `mix release` hot upgrades).
  """
  @impl true
  def config_change(changed, _new, removed) do
    DataWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
