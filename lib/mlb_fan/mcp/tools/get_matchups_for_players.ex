defmodule MlbFan.Mcp.Tools.GetMatchupsForPlayers do
  @moduledoc "Given a list of hitters, find today's game for each hitter's team and the opposing probable starting pitcher. Returns hitter→opponent-pitcher pairs with basic stats for both."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Mcp.Params
  alias MlbFan.Stats

  schema do
    field :player_mlb_ids, {:required, {:list, :integer}},
      description: "MLB person ids (max #{Params.max_ids()}; extra ids are dropped)."

    field :date, :string, description: "ISO date YYYY-MM-DD. Defaults to today."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    # Clamp the id-list at the trust boundary to bound per-player fan-out.
    {ids, truncated?} = Params.id_list(params["player_mlb_ids"] || params[:player_mlb_ids])
    date = params["date"] || params[:date]

    ids
    |> Stats.matchups_for_players(date)
    |> Params.maybe_note(truncated?, "player_mlb_ids")
  end
end
