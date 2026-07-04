defmodule MlbFan.Mcp.Server do
  @moduledoc """
  Hermes MCP server exposing the 9 MLB/research tools and 2 prompts over
  Streamable HTTP (mounted at `/mcp` in the router). Any MCP client — the
  internal Jido agent's client or an external one like Claude Desktop — can
  connect, `tools/list`, `tools/call`, `prompts/list`, and `prompts/get`.
  """
  use Hermes.Server,
    name: "mlb-fan-agent",
    version: "1.0.0",
    capabilities: [:tools, :prompts]

  # Tools (stable order — mirrors MlbFan.Mcp.Catalog).
  component(MlbFan.Mcp.Tools.GetSchedule)
  component(MlbFan.Mcp.Tools.GetBoxscore)
  component(MlbFan.Mcp.Tools.GetHomersByDate)
  component(MlbFan.Mcp.Tools.GetPlayerStreaks)
  component(MlbFan.Mcp.Tools.LookupPlayer)
  component(MlbFan.Mcp.Tools.GetPlayerStats)
  component(MlbFan.Mcp.Tools.GetProbablePitchers)
  component(MlbFan.Mcp.Tools.GetMatchupsForPlayers)
  component(MlbFan.Mcp.Tools.ResearchPlayerMatchup)

  # Prompts (mirror the two default question buttons).
  component(MlbFan.Mcp.Prompts.HrsYesterdayWithStreaks)
  component(MlbFan.Mcp.Prompts.MatchupOddsFollowup)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
