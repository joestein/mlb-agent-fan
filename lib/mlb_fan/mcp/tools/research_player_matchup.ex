defmodule MlbFan.Mcp.Tools.ResearchPlayerMatchup do
  @moduledoc "Deep web research for a single hitter-vs-pitcher matchup: recent form, the pitcher's HR vulnerability vs the hitter's handedness, ballpark HR factor, and weather/forecast. Returns compact research snippets with source URLs for the model to synthesize into a likelihood assessment. Call once per hitter; calls run in parallel."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Research.Matchup

  schema do
    field :hitter_name, {:required, :string}
    field :hitter_mlb_id, :integer
    field :pitcher_name, {:required, :string}
    field :pitcher_mlb_id, :integer
    field :venue, :string
    field :date, :string, description: "ISO date YYYY-MM-DD."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    Matchup.research(%{
      hitter_name: params["hitter_name"] || params[:hitter_name],
      hitter_mlb_id: params["hitter_mlb_id"] || params[:hitter_mlb_id],
      pitcher_name: params["pitcher_name"] || params[:pitcher_name],
      pitcher_mlb_id: params["pitcher_mlb_id"] || params[:pitcher_mlb_id],
      venue: params["venue"] || params[:venue],
      date: params["date"] || params[:date],
      # ToolRouter injects "session_id" so Exa spend is attributed to the
      # session (cost model spec §10 / G4 and the spend cap). Thread it through.
      session_id: params["session_id"] || params[:session_id]
    })
  end
end
