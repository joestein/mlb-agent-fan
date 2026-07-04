defmodule MlbFan.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        MlbFanWeb.Telemetry,
        MlbFan.Repo,
        {DNSCluster, query: Application.get_env(:mlb_fan, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: MlbFan.PubSub},
        # Registry + supervisor for per-session chat conversation processes.
        {Registry, keys: :unique, name: MlbFan.ChatRegistry},
        {DynamicSupervisor, name: MlbFan.ConversationSupervisor, strategy: :one_for_one}
      ] ++
        mcp_children() ++
        [MlbFanWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MlbFan.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start the Hermes MCP server (Streamable HTTP) unless disabled (e.g. in tests
  # where tool logic is exercised directly and no endpoint runs).
  defp mcp_children do
    if Application.get_env(:mlb_fan, :start_mcp, true) do
      [
        # Hermes' process registry must be up before the server starts.
        Hermes.Server.Registry,
        {MlbFan.Mcp.Server, transport: :streamable_http}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MlbFanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
