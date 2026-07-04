defmodule MlbFan.Mcp.Tools.GetBoxscore do
  @moduledoc "Get the full box score for a single game by its gamePk: per-player batting and pitching lines for both teams."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Mcp.Json
  alias MlbFan.Stats

  schema do
    field :game_pk, {:required, :integer}, description: "MLB gamePk from the schedule."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    game_pk = to_int(params["game_pk"] || params[:game_pk])

    if is_integer(game_pk) do
      Map.put(Json.boxscore(Stats.boxscore(game_pk)), "game_pk", game_pk)
    else
      %{"error" => "game_pk is required and must be an integer"}
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: with({n, _} <- Integer.parse(v), do: n, else: (_ -> nil))
  defp to_int(_), do: nil
end
