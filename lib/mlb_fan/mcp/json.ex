defmodule MlbFan.Mcp.Json do
  @moduledoc "Shapers converting internal Stats structs/maps into JSON-safe tool results."

  alias MlbFan.Stats

  @doc "Resolve a possibly-nil ISO date param to an ISO string (default today ET)."
  def date_or_today(nil), do: Date.to_iso8601(Stats.today())
  def date_or_today(%Date{} = d), do: Date.to_iso8601(d)
  def date_or_today(s) when is_binary(s), do: s

  def date_or_yesterday(nil), do: Date.to_iso8601(Stats.yesterday())
  def date_or_yesterday(%Date{} = d), do: Date.to_iso8601(d)
  def date_or_yesterday(s) when is_binary(s), do: s

  @doc "Shape a normalized schedule game map into JSON-safe string-keyed data."
  def game(g) do
    %{
      "game_pk" => g[:game_pk],
      "game_date" => iso(g[:game_date]),
      "status" => g[:abstract_state],
      "detailed_state" => g[:detailed_state],
      "venue" => g[:venue_name],
      "home" => %{
        "team_mlb_id" => g[:home_team_mlb_id],
        "team" => g[:home_team_name],
        "score" => g[:home_score],
        "probable_pitcher_mlb_id" => g[:home_probable_pitcher_mlb_id],
        "probable_pitcher" => g[:home_probable_pitcher_name]
      },
      "away" => %{
        "team_mlb_id" => g[:away_team_mlb_id],
        "team" => g[:away_team_name],
        "score" => g[:away_score],
        "probable_pitcher_mlb_id" => g[:away_probable_pitcher_mlb_id],
        "probable_pitcher" => g[:away_probable_pitcher_name]
      }
    }
  end

  @doc "Shape a parsed boxscore (`%{home:, away:}`) into JSON-safe data."
  def boxscore(%{home: home, away: away}) do
    %{"home" => side(home), "away" => side(away)}
  end

  defp side(s) do
    %{
      "team_mlb_id" => s[:team_mlb_id],
      "batting" => Enum.map(s[:batting] || [], &jsonify/1),
      "pitching" => Enum.map(s[:pitching] || [], &jsonify/1)
    }
  end

  defp jsonify(map) do
    Map.new(map, fn
      {k, %Decimal{} = v} -> {to_string(k), Decimal.to_string(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp iso(%Date{} = d), do: Date.to_iso8601(d)
  defp iso(other), do: other
end
