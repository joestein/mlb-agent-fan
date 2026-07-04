defmodule MlbFan.Mcp.Prompts.MatchupOddsFollowup do
  @moduledoc "Today's matchups + chances for the players who homered yesterday (default question #2)."
  use Hermes.Server.Component, type: :prompt

  alias Hermes.Server.Response

  schema do
    field :player_mlb_ids, {:required, {:list, :integer}},
      description: "The HR-hitter MLB ids from the prior answer."

    field :date, :string, description: "ISO date YYYY-MM-DD. Defaults to today."
  end

  @impl true
  def get_messages(args, frame) do
    {:reply, Response.user_message(Response.prompt(), text(args)), frame}
  end

  @doc "Frozen prompt text (spec §5.10)."
  def text(args) do
    ids = args["player_mlb_ids"] || args[:player_mlb_ids] || []
    ids_str = ids |> List.wrap() |> Enum.map_join(", ", &to_string/1)

    "From the list of players who homered yesterday (#{ids_str}), determine who is playing today " <>
      "and against which probable starting pitcher, then assess each hitter's chance of doing well today " <>
      "(especially multi-HR / back-to-back-HR potential) based on the pitcher's and hitter's stats plus " <>
      "deep research. Use get_matchups_for_players, then call research_player_matchup once per hitter. " <>
      "For each hitter give a 1–10 confidence score, the key supporting factors, and cite sources. " <>
      "Rank the list best-to-worst. Include the responsible-gambling note."
  end
end
