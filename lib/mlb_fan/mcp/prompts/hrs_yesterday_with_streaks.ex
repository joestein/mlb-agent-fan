defmodule MlbFan.Mcp.Prompts.HrsYesterdayWithStreaks do
  @moduledoc "Home runs on a date with each hitter's current HR + hitting streak (default question #1)."
  use Hermes.Server.Component, type: :prompt

  alias Hermes.Server.Response
  alias MlbFan.Stats

  schema do
    field :date, :string,
      description: "ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York)."
  end

  @impl true
  def get_messages(args, frame) do
    {:reply, Response.user_message(Response.prompt(), text(args)), frame}
  end

  @doc "Frozen prompt text (spec §5.10)."
  def text(args) do
    date = args["date"] || args[:date] || Date.to_iso8601(Stats.yesterday())

    "For #{date}, list everyone who hit a home run and, for each of those players, their current " <>
      "home-run streak (consecutive team games with at least one HR) and hitting streak. Use " <>
      "get_homers_by_date then get_player_streaks. Present a clean table sorted by HR streak descending, " <>
      "then a short note on any multi-HR games that day."
  end
end
