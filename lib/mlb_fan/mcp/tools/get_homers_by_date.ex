defmodule MlbFan.Mcp.Tools.GetHomersByDate do
  @moduledoc "List every home run hit on a given date across MLB, with the batter, the pitcher who allowed it, the teams, inning, and RBIs. Use for 'who hit a home run yesterday'."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Stats

  schema do
    field :date, :string,
      description: "ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York)."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    date = params["date"] || params[:date] || Date.to_iso8601(Stats.yesterday())
    Stats.homers_by_date(date)
  end
end
