defmodule MlbFan.Mcp.Tools.GetProbablePitchers do
  @moduledoc "For a date, list each game's probable starting pitchers (home and away) with ids and hands. Use to find who a hitter's team faces today."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Stats

  schema do
    field :date, :string, description: "ISO date YYYY-MM-DD. Defaults to today."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    date = params["date"] || params[:date]
    Stats.probable_pitchers(date)
  end
end
