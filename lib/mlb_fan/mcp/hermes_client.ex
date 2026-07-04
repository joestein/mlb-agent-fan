defmodule MlbFan.Mcp.HermesClient do
  @moduledoc """
  A real `hermes_mcp` client that connects to the mounted MLB Fan MCP server over
  Streamable HTTP. Used when `:mlb_fan, :mcp_dispatch` is `:hermes` (to
  demonstrate an external MCP client round-trip). Start it in a supervision tree
  with a transport, e.g.:

      {MlbFan.Mcp.HermesClient,
       transport: {:streamable_http, base_url: Application.get_env(:mlb_fan, :mcp_base_url)}}

  The default in-process dispatch (`:direct`) does not require this process.
  """
  use Hermes.Client,
    name: "mlb-fan-internal",
    version: "1.0.0",
    protocol_version: "2025-03-26",
    capabilities: [:roots]
end
