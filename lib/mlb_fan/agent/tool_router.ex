defmodule MlbFan.Agent.ToolRouter do
  @moduledoc """
  Executes all `tool_use` blocks from one assistant turn concurrently through
  `MlbFan.Mcp.Client` and assembles them into a SINGLE user message carrying all
  `tool_result` blocks (spec §6.4). Concurrency and per-tool timeouts are
  bounded (spec §9/§13); errors become `is_error` tool_result blocks so the loop
  can continue and the model can react.
  """

  require Logger

  alias MlbFan.Mcp.Client

  @doc """
  Run all tool_use blocks. Returns the tool_result content blocks (order
  irrelevant; each carries its `tool_use_id`).
  """
  @spec run([map()], keyword()) :: [map()]
  def run(tool_use_blocks, opts \\ []) do
    cfg = Application.get_env(:mlb_fan, :agent, [])
    concurrency = Keyword.get(cfg, :tool_concurrency, 8)
    session_id = Keyword.get(opts, :session_id)

    tool_use_blocks
    |> Task.async_stream(
      fn block -> execute(block, session_id) end,
      max_concurrency: concurrency,
      timeout: max_timeout(cfg),
      on_timeout: :kill_task
    )
    |> Enum.zip(tool_use_blocks)
    |> Enum.map(fn
      {{:ok, result_block}, _block} -> result_block
      {{:exit, _reason}, block} -> error_block(block["id"], "tool timed out")
    end)
  end

  defp execute(%{"id" => id, "name" => name} = block, session_id) do
    input = block["input"] || %{}
    input = maybe_inject_session(name, input, session_id)

    case Client.call_tool(name, input) do
      {:ok, result} ->
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => encode(result)
        }

      {:error, reason} ->
        error_block(id, "tool error: #{inspect(reason)}")
    end
  end

  # Give research tool the session id so its Exa spend is attributed.
  defp maybe_inject_session("research_player_matchup", input, session_id)
       when is_binary(session_id),
       do: Map.put(input, "session_id", session_id)

  defp maybe_inject_session(_name, input, _session), do: input

  defp error_block(id, message) do
    %{"type" => "tool_result", "tool_use_id" => id, "is_error" => true, "content" => message}
  end

  defp encode(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _} -> inspect(result)
    end
  end

  defp max_timeout(cfg) do
    max(
      Keyword.get(cfg, :tool_timeout_ms, 30_000),
      Keyword.get(cfg, :research_timeout_ms, 60_000)
    ) +
      1_000
  end
end
