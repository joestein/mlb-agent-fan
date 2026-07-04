defmodule MlbFan.Mcp.Client do
  @moduledoc """
  The MCP client the Jido agent uses for `tools/call` and `prompts/get`.

  Two dispatch modes (config `:mlb_fan, :mcp_dispatch`):

    * `:direct` (default) — invoke the tool component's in-process `run/1`. This
      is the same module registered on the Hermes server, so behaviour is
      identical, but it avoids a network hop and keeps the test suite fully
      offline and deterministic.
    * `:hermes` — round-trip through the mounted Hermes Streamable-HTTP server
      via `MlbFan.Mcp.HermesClient` (used to demonstrate an external MCP client
      connection; see the round-trip integration test).
  """

  alias MlbFan.Mcp.Catalog

  @doc "Call a tool by name with a JSON-decoded input map. Returns `{:ok, result_map}` or `{:error, reason}`."
  @spec call_tool(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(name, input) when is_binary(name) and is_map(input) do
    case dispatch_mode() do
      :hermes -> hermes_call(name, input)
      _ -> direct_call(name, input)
    end
  end

  defp direct_call(name, input) do
    case Catalog.module_for(name) do
      {:ok, module} ->
        try do
          {:ok, module.run(input)}
        rescue
          e -> {:error, Exception.message(e)}
        end

      :error ->
        {:error, "unknown tool: #{name}"}
    end
  end

  defp hermes_call(name, input) do
    case MlbFan.Mcp.HermesClient.call_tool(name, input) do
      {:ok, response} -> {:ok, extract_result(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Hermes returns a response struct/map; pull out the decoded tool result.
  defp extract_result(%{result: result}), do: result
  defp extract_result(%{"result" => result}), do: result
  defp extract_result(other), do: other

  @doc "Get a parameterized prompt's rendered user text by name."
  @spec get_prompt(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def get_prompt("hrs_yesterday_with_streaks", args),
    do: {:ok, MlbFan.Mcp.Prompts.HrsYesterdayWithStreaks.text(args)}

  def get_prompt("matchup_odds_followup", args),
    do: {:ok, MlbFan.Mcp.Prompts.MatchupOddsFollowup.text(args)}

  def get_prompt(name, _args), do: {:error, "unknown prompt: #{name}"}

  defp dispatch_mode, do: Application.get_env(:mlb_fan, :mcp_dispatch, :direct)
end
