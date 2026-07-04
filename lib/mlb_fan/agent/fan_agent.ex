defmodule MlbFan.Agent.FanAgent do
  @moduledoc """
  The Jido agent for MLB Fan Agent. It is the orchestration unit that connects to
  the MCP server (via `MlbFan.Mcp.Client`) for tool calls and prompts; its
  `RunTurnAction` drives the Anthropic tool-use loop (spec §15 R2 fallback).
  """
  use Jido.Agent,
    name: "mlb_fan_agent",
    description: "Daily MLB home-run streak & matchup research agent.",
    actions: [MlbFan.Agent.RunTurnAction]
end
