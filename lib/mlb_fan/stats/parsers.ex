defmodule MlbFan.Stats.Parsers do
  @moduledoc """
  Pure functions turning raw `statsapi` JSON into normalized maps the facade
  persists and the tools return. Kept side-effect free so they are unit-testable
  against captured fixtures with no DB or network.
  """

  # ── schedule ──────────────────────────────────────────────────────────────

  @doc "Parse `/schedule` into a flat list of normalized game maps."
  @spec parse_schedule(map()) :: [map()]
  def parse_schedule(%{"dates" => dates}) when is_list(dates) do
    Enum.flat_map(dates, fn %{"games" => games} -> Enum.map(games, &parse_game/1) end)
  end

  def parse_schedule(_), do: []

  defp parse_game(g) do
    status = g["status"] || %{}
    teams = g["teams"] || %{}
    home = teams["home"] || %{}
    away = teams["away"] || %{}
    venue = g["venue"] || %{}

    %{
      game_pk: g["gamePk"],
      game_date: parse_date(g["officialDate"] || g["gameDate"]),
      game_datetime: parse_datetime(g["gameDate"]),
      game_type: g["gameType"],
      double_header: g["doubleHeader"],
      game_number: g["gameNumber"],
      abstract_state: status["abstractGameState"],
      detailed_state: status["detailedState"],
      home_team_mlb_id: get_in(home, ["team", "id"]),
      away_team_mlb_id: get_in(away, ["team", "id"]),
      home_team_name: get_in(home, ["team", "name"]),
      away_team_name: get_in(away, ["team", "name"]),
      home_score: home["score"],
      away_score: away["score"],
      home_probable_pitcher_mlb_id: get_in(home, ["probablePitcher", "id"]),
      home_probable_pitcher_name: get_in(home, ["probablePitcher", "fullName"]),
      away_probable_pitcher_mlb_id: get_in(away, ["probablePitcher", "id"]),
      away_probable_pitcher_name: get_in(away, ["probablePitcher", "fullName"]),
      venue_mlb_id: venue["id"],
      venue_name: venue["name"]
    }
  end

  # ── boxscore ──────────────────────────────────────────────────────────────

  @doc "Parse `/boxscore` into `%{home: side, away: side}` where each side has batting/pitching lists."
  @spec parse_boxscore(map()) :: map()
  def parse_boxscore(%{"teams" => %{"home" => home, "away" => away}}) do
    %{home: parse_side(home), away: parse_side(away)}
  end

  def parse_boxscore(_),
    do: %{
      home: %{team_mlb_id: nil, batting: [], pitching: []},
      away: %{team_mlb_id: nil, batting: [], pitching: []}
    }

  defp parse_side(side) do
    team_id = get_in(side, ["team", "id"])
    players = side["players"] || %{}
    values = Map.values(players)

    %{
      team_mlb_id: team_id,
      batting: values |> Enum.map(&parse_batting_line(&1, team_id)) |> Enum.reject(&is_nil/1),
      pitching: values |> Enum.map(&parse_pitching_line(&1, team_id)) |> Enum.reject(&is_nil/1)
    }
  end

  defp parse_batting_line(player, team_id) do
    batting = get_in(player, ["stats", "batting"]) || %{}
    person_id = get_in(player, ["person", "id"])

    if person_id && map_size(batting) > 0 do
      pa = int(batting["plateAppearances"])
      ab = int(batting["atBats"])

      %{
        player_mlb_id: person_id,
        team_mlb_id: team_id,
        batting_order: parse_batting_order(player["battingOrder"]),
        plate_appearances: pa,
        at_bats: ab,
        hits: int(batting["hits"]),
        doubles: int(batting["doubles"]),
        triples: int(batting["triples"]),
        home_runs: int(batting["homeRuns"]),
        rbi: int(batting["rbi"]),
        walks: int(batting["baseOnBalls"]),
        strikeouts: int(batting["strikeOuts"]),
        appeared: appeared?(player, pa)
      }
    end
  end

  defp parse_pitching_line(player, team_id) do
    pitching = get_in(player, ["stats", "pitching"]) || %{}
    person_id = get_in(player, ["person", "id"])

    if person_id && map_size(pitching) > 0 do
      outs = ip_to_outs(pitching["inningsPitched"])

      %{
        player_mlb_id: person_id,
        team_mlb_id: team_id,
        innings_pitched: decimal(pitching["inningsPitched"]),
        outs: outs,
        hits_allowed: int(pitching["hits"]),
        runs: int(pitching["runs"]),
        earned_runs: int(pitching["earnedRuns"]),
        home_runs_allowed: int(pitching["homeRuns"]),
        walks: int(pitching["baseOnBalls"]),
        strikeouts: int(pitching["strikeOuts"]),
        batters_faced: int(pitching["battersFaced"]),
        is_starter: int(pitching["gamesStarted"]) > 0
      }
    end
  end

  # ── play-by-play (home runs) ──────────────────────────────────────────────

  @doc "Extract home-run events from `/playByPlay` (`allPlays` where eventType == home_run)."
  @spec parse_playbyplay_hrs(map()) :: [map()]
  def parse_playbyplay_hrs(%{"allPlays" => plays}) when is_list(plays) do
    plays
    |> Enum.filter(fn p -> get_in(p, ["result", "eventType"]) == "home_run" end)
    |> Enum.map(&parse_hr_play/1)
  end

  def parse_playbyplay_hrs(_), do: []

  defp parse_hr_play(play) do
    result = play["result"] || %{}
    about = play["about"] || %{}
    matchup = play["matchup"] || %{}

    %{
      batter_mlb_id: get_in(matchup, ["batter", "id"]),
      batter_name: get_in(matchup, ["batter", "fullName"]),
      pitcher_mlb_id: get_in(matchup, ["pitcher", "id"]),
      pitcher_name: get_in(matchup, ["pitcher", "fullName"]),
      inning: about["inning"],
      half_inning: about["halfInning"],
      rbi: int(result["rbi"]),
      description: result["description"],
      at_bat_index: about["atBatIndex"]
    }
  end

  # ── person ────────────────────────────────────────────────────────────────

  @doc "Parse `/people/:id` (or the first of `/people/search`) into a player bio map."
  @spec parse_person(map()) :: map() | nil
  def parse_person(%{"people" => [person | _]}), do: parse_person(person)
  def parse_person(%{"people" => []}), do: nil

  def parse_person(%{"id" => _} = person) do
    %{
      mlb_id: person["id"],
      full_name: person["fullName"],
      first_name: person["firstName"],
      last_name: person["lastName"],
      primary_position: get_in(person, ["primaryPosition", "abbreviation"]),
      bat_side: get_in(person, ["batSide", "code"]),
      pitch_hand: get_in(person, ["pitchHand", "code"]),
      current_team_mlb_id: get_in(person, ["currentTeam", "id"]),
      active: Map.get(person, "active", true)
    }
  end

  def parse_person(_), do: nil

  @doc "Parse all people from `/people/search` into bio maps."
  @spec parse_people(map()) :: [map()]
  def parse_people(%{"people" => people}) when is_list(people),
    do: Enum.map(people, &parse_person/1)

  def parse_people(_), do: []

  # ── stats ─────────────────────────────────────────────────────────────────

  @doc "Parse `/people/:id/stats` season split into a flat stat map (keys are the raw stat names)."
  @spec parse_stats(map()) :: map()
  def parse_stats(%{"stats" => stats}) when is_list(stats) do
    stats
    |> Enum.flat_map(fn s -> s["splits"] || [] end)
    |> List.first()
    |> case do
      %{"stat" => stat} when is_map(stat) -> stat
      _ -> %{}
    end
  end

  def parse_stats(_), do: %{}

  # ── helpers ───────────────────────────────────────────────────────────────

  @doc "Innings-pitched string (\"6.1\") to whole outs (19)."
  @spec ip_to_outs(term()) :: integer()
  def ip_to_outs(nil), do: 0

  def ip_to_outs(ip) when is_binary(ip) do
    case String.split(ip, ".") do
      [whole] -> to_int(whole) * 3
      [whole, frac] -> to_int(whole) * 3 + to_int(frac)
      _ -> 0
    end
  end

  def ip_to_outs(ip) when is_number(ip) do
    whole = trunc(ip)
    frac = round((ip - whole) * 10)
    whole * 3 + frac
  end

  defp parse_batting_order(nil), do: nil
  defp parse_batting_order(order) when is_binary(order), do: to_int(order)
  defp parse_batting_order(order) when is_integer(order), do: order

  # A player "appeared" if they took the field / had a PA; the presence of a
  # non-empty batting stat block with a batting order or any PA is our signal.
  defp appeared?(player, pa) do
    pa > 0 or not is_nil(player["battingOrder"]) or
      int(get_in(player, ["stats", "batting", "gamesPlayed"])) > 0
  end

  defp int(nil), do: 0
  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(s) when is_binary(s), do: to_int(s)
  defp int(_), do: 0

  defp to_int(s) do
    case Integer.parse(to_string(s)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp decimal(nil), do: nil

  defp decimal(v) do
    case Decimal.parse(to_string(v)) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(String.slice(s, 0, 10)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
