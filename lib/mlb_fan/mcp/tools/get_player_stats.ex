defmodule MlbFan.Mcp.Tools.GetPlayerStats do
  @moduledoc "Get a player's season hitting or pitching stats for a given season and group."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Stats

  schema do
    field :player_mlb_id, {:required, :integer}
    field :group, {:enum, ["hitting", "pitching"]}
    field :season, :integer, description: "4-digit year. Defaults to current season."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    id = to_int(params["player_mlb_id"] || params[:player_mlb_id])
    group = params["group"] || params[:group] || "hitting"
    season = to_int(params["season"] || params[:season])
    opts = [group: group] ++ if(season, do: [season: season], else: [])

    if is_integer(id) do
      Stats.player_stats(id, opts)
    else
      %{"error" => "player_mlb_id is required and must be an integer"}
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: with({n, _} <- Integer.parse(v), do: n, else: (_ -> nil))
  defp to_int(_), do: nil
end
