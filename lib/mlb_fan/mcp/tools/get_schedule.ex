defmodule MlbFan.Mcp.Tools.GetSchedule do
  @moduledoc "Get the MLB game schedule for a date, including teams, status, venue, and probable starting pitchers. Use to find which games are played on a given day."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Mcp.Json
  alias MlbFan.Stats

  schema do
    field :date, :string,
      description: "ISO date YYYY-MM-DD. Defaults to today (America/New_York)."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  @doc "In-process tool logic (used by the agent tool router and tests)."
  def run(params) do
    date = params["date"] || params[:date]
    games = Stats.schedule(date)
    %{"date" => Json.date_or_today(date), "games" => Enum.map(games, &Json.game/1)}
  end
end
