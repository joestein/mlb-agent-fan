defmodule MlbFan.Mcp.Tools.GetPlayerStreaks do
  @moduledoc "For one or more players, compute their current home-run streak and hitting streak over the last N team games. HR streak = consecutive team games with at least one HR by the player. Hitting streak = consecutive games with at least one hit. Days off do not break a streak."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Mcp.Params
  alias MlbFan.Stats

  schema do
    field :player_mlb_ids, {:required, {:list, :integer}},
      description: "MLB person ids (max #{Params.max_ids()}; extra ids are dropped)."

    field :window_days, :integer, description: "Days of game logs to scan back (1-60; clamped)."
    field :as_of_date, :string, description: "ISO date; streak computed as of end of this day."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    # Clamp at the trust boundary: model-supplied ids/window can be steered by
    # prompt injection in untrusted web content into an unbounded fetch fan-out.
    {ids, truncated?} = Params.id_list(params["player_mlb_ids"] || params[:player_mlb_ids])
    window = Params.window(params["window_days"] || params[:window_days])
    as_of = params["as_of_date"] || params[:as_of_date]

    ids
    |> Stats.player_streaks(window_days: window, as_of: as_of)
    |> Params.maybe_note(truncated?, "player_mlb_ids")
  end
end
