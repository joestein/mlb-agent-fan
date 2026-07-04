defmodule MlbFan.Stats do
  @moduledoc """
  Public facade over the MLB-StatsAPI port + Postgres mirror. Every function is
  **DB-first read-through**: raw responses are cached in `raw_responses`
  (`MlbFan.Cache`), and derived rows (games, batting/pitching lines, HR events,
  players) are idempotently upserted so streaks and matchups can be computed
  purely from the DB (spec §1 G3, §8.3).
  """

  import Ecto.Query
  require Logger

  alias MlbFan.Cache
  alias MlbFan.Cache.Keys
  alias MlbFan.Mlb.Schemas.{BattingLine, BoxScore, Game, HomeRunEvent, PitchingLine, Player}
  alias MlbFan.Mlb.Schemas.RawResponse
  alias MlbFan.Repo
  alias MlbFan.Stats.{Api, Parsers, Streaks}

  @tz "America/New_York"

  # Defense-in-depth caps (spec §13). The MCP tools clamp at the trust boundary
  # (`MlbFan.Mcp.Params`); these guard the facade even if called directly, so a
  # runaway `window_days`/id-list can never drive an unbounded fetch fan-out.
  @max_window_days 60
  @max_players 25

  # ── date helpers ────────────────────────────────────────────────────────

  @doc "Today in America/New_York."
  @spec today() :: Date.t()
  def today do
    case DateTime.now(@tz) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  @spec yesterday() :: Date.t()
  def yesterday, do: Date.add(today(), -1)

  defp to_date(nil), do: today()
  defp to_date(%Date{} = d), do: d

  defp to_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> today()
    end
  end

  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  # ── schedule ────────────────────────────────────────────────────────────

  @doc "Schedule for a date; upserts games + probable pitchers, returns normalized game maps."
  @spec schedule(Date.t() | String.t() | nil, keyword()) :: [map()]
  def schedule(date, _opts \\ []) do
    d = to_date(date)

    params = %{
      "sportId" => 1,
      "date" => iso(d),
      "hydrate" => "probablePitcher,linescore,venue,team"
    }

    case Cache.fetch_or_fetch("schedule", params, fn -> Api.get("schedule", %{}, params) end) do
      {:ok, body, _} ->
        games = Parsers.parse_schedule(body)
        Enum.each(games, &upsert_game/1)
        games

      {:error, reason} ->
        Logger.warning("schedule fetch failed: #{inspect(reason)}")
        []
    end
  end

  # ── boxscore ────────────────────────────────────────────────────────────

  @doc "Box score for a game; upserts batting/pitching lines. Returns parsed sides."
  @spec boxscore(integer()) :: map()
  def boxscore(game_pk) when is_integer(game_pk) do
    game = Repo.get_by(Game, game_pk: game_pk)
    game_date = game && game.game_date
    final? = game && Game.final?(game)

    result =
      Cache.fetch_or_fetch(
        "boxscore",
        %{"game_pk" => game_pk},
        fn ->
          case Api.get("boxscore", %{"game_pk" => game_pk}) do
            {:ok, body} -> {:ok, body, %{immutable: final? || false}}
            err -> err
          end
        end
      )

    case result do
      {:ok, body, _} ->
        parsed = Parsers.parse_boxscore(body)
        persist_lines(parsed, game_pk, game_date)
        mark_box_ingested(game_pk, final? || false)
        parsed

      {:error, _} ->
        %{home: %{batting: [], pitching: []}, away: %{batting: [], pitching: []}}
    end
  end

  # ── homers by date ──────────────────────────────────────────────────────

  @doc """
  Every home run on a date, with batter + pitcher attribution (from play-by-play).
  Fills `home_run_events` on miss, then serves from the DB.
  """
  @spec homers_by_date(Date.t() | String.t() | nil) :: map()
  def homers_by_date(date) do
    d = to_date(date)
    games = schedule(d)

    for g <- games, g[:abstract_state] in ["Final", "Live"], g[:game_pk] do
      ensure_home_runs(g)
    end

    hrs =
      Repo.all(
        from h in HomeRunEvent,
          where: h.game_date == ^d,
          order_by: [asc: h.game_pk, asc: h.at_bat_index]
      )

    home_runs = Enum.map(hrs, &hr_json/1)
    %{"date" => iso(d), "count" => length(home_runs), "home_runs" => home_runs}
  end

  # Ingest a game's home runs. We short-circuit ONLY once the game's play-by-play
  # has been ingested while Final (its HR set is then immutable). Gating on
  # *finality* rather than mere HomeRunEvent row existence is essential: a game
  # first seen while Live records only HRs-so-far; keying the skip on row
  # existence would freeze that partial set forever, dropping later HRs even
  # after the game goes Final and the short-TTL playByPlay cache refreshes.
  # For any not-yet-Final-ingested game we re-fetch through the cache (Live =
  # short TTL) and upsert; the unique index on (game_pk, at_bat_index) makes
  # re-ingestion idempotent (spec §8.3 / §4.8).
  defp ensure_home_runs(game) do
    pk = game[:game_pk]
    final? = game[:abstract_state] == "Final"

    if hr_final_ingested?(pk) do
      :ok
    else
      result =
        Cache.fetch_or_fetch(
          "playByPlay",
          %{"game_pk" => pk},
          fn ->
            case Api.get("playByPlay", %{"game_pk" => pk}) do
              {:ok, body} -> {:ok, body, %{immutable: final?}}
              err -> err
            end
          end
        )

      case result do
        {:ok, body, _} ->
          body |> Parsers.parse_playbyplay_hrs() |> Enum.each(&upsert_home_run(&1, game))

        _ ->
          :ok
      end
    end
  end

  # The playByPlay cache row is stored immutable only when fetched while Final,
  # so an immutable row is a durable "ingested at Final" marker.
  defp hr_final_ingested?(pk) do
    hash = Keys.params_hash(%{"game_pk" => pk})

    case Cache.get_row("playByPlay", hash) do
      %RawResponse{immutable: true} -> true
      _ -> false
    end
  end

  # ── player streaks ──────────────────────────────────────────────────────

  @doc """
  Compute HR + hitting streaks for players over a window. Ensures the mirror has
  the team's Final-game box scores in the window, then computes purely from
  `batting_lines` (spec §8).
  """
  @spec player_streaks([integer()], keyword()) :: map()
  def player_streaks(ids, opts \\ []) when is_list(ids) do
    window_days = clamp_window(Keyword.get(opts, :window_days, 30))
    as_of = to_date(Keyword.get(opts, :as_of))

    players =
      ids
      |> cap_players()
      |> Enum.map(fn id ->
        ensure_player_window(id, as_of, window_days)
        compute_player_streak(id, as_of, window_days)
      end)

    %{"as_of" => iso(as_of), "players" => players}
  end

  defp compute_player_streak(id, as_of, window_days) do
    start_date = Date.add(as_of, -window_days)
    player = Repo.get_by(Player, mlb_id: id)

    # Join `games` to carry `game_number` so the streak walk can order
    # doubleheaders by (game_date, game_number) per spec §8.2 rule 1/5 — the
    # game_pk of a split/rescheduled DH is not a reliable proxy for game order.
    lines =
      Repo.all(
        from b in BattingLine,
          join: g in Game,
          on: g.game_pk == b.game_pk,
          where: b.player_mlb_id == ^id and b.game_date >= ^start_date and b.game_date <= ^as_of,
          order_by: [asc: b.game_date, asc: g.game_number, asc: b.game_pk],
          select: %{
            game_date: b.game_date,
            game_pk: b.game_pk,
            game_number: g.game_number,
            at_bats: b.at_bats,
            hits: b.hits,
            home_runs: b.home_runs,
            plate_appearances: b.plate_appearances,
            appeared: b.appeared
          }
      )

    result = Streaks.compute(lines, window_days: window_days)

    %{
      "mlb_id" => id,
      "name" => (player && player.full_name) || nil,
      "hr_streak" => result.hr_streak,
      "hitting_streak" => result.hitting_streak,
      "last_hr_date" => result.last_hr_date && Date.to_iso8601(result.last_hr_date),
      "games_scanned" => result.games_scanned,
      "window_truncated" => result.window_truncated
    }
  end

  # Ensure this player's team Final games in the window are mirrored with a
  # batting_line for the player.
  defp ensure_player_window(id, as_of, window_days) do
    player = resolve_player(id)
    team_id = player && player.current_team_mlb_id
    start_date = Date.add(as_of, -window_days)

    if team_id do
      for offset <- 0..window_days do
        day = Date.add(start_date, offset)
        if Date.compare(day, as_of) != :gt, do: schedule(day)
      end

      team_games =
        Repo.all(
          from g in Game,
            where:
              g.game_date >= ^start_date and g.game_date <= ^as_of and
                g.abstract_state == "Final" and
                (g.home_team_mlb_id == ^team_id or g.away_team_mlb_id == ^team_id)
        )

      for g <- team_games do
        unless Repo.exists?(
                 from b in BattingLine, where: b.game_pk == ^g.game_pk and b.player_mlb_id == ^id
               ) do
          boxscore(g.game_pk)
        end
      end
    end

    :ok
  end

  # ── lookup / stats / probables / matchups ────────────────────────────────

  @doc "Resolve a name to MLB people (upserts players)."
  @spec lookup_player(String.t()) :: map()
  def lookup_player(name) when is_binary(name) do
    params = %{"names" => name}

    case Cache.fetch_or_fetch("people_search", params, fn ->
           Api.get("people_search", %{}, params)
         end) do
      {:ok, body, _} ->
        people = Parsers.parse_people(body)
        Enum.each(people, &upsert_player/1)
        %{"query" => name, "players" => Enum.map(people, &player_json/1)}

      {:error, _} ->
        %{"query" => name, "players" => []}
    end
  end

  @doc "Bat side (\"L\"/\"R\"/\"S\") for a player id, or nil if unknown."
  @spec player_bat_side(integer() | nil) :: String.t() | nil
  def player_bat_side(nil), do: nil

  def player_bat_side(id) do
    case resolve_player(id) do
      %Player{bat_side: side} -> side
      _ -> nil
    end
  end

  @doc "Season hitting/pitching stats for a player."
  @spec player_stats(integer(), keyword()) :: map()
  def player_stats(id, opts \\ []) when is_integer(id) do
    group = Keyword.get(opts, :group, "hitting")
    season = Keyword.get(opts, :season, today().year)

    params = %{"stats" => "season", "group" => group, "season" => season}

    case Cache.fetch_or_fetch(
           "player_stats",
           Map.put(params, "person_id", id),
           fn -> Api.get("player_stats", %{"person_id" => id}, params) end
         ) do
      {:ok, body, _} ->
        %{
          "player_mlb_id" => id,
          "group" => group,
          "season" => season,
          "stats" => Parsers.parse_stats(body)
        }

      {:error, _} ->
        %{"player_mlb_id" => id, "group" => group, "season" => season, "stats" => %{}}
    end
  end

  @doc "Probable starting pitchers per game for a date."
  @spec probable_pitchers(Date.t() | String.t() | nil) :: map()
  def probable_pitchers(date) do
    d = to_date(date)
    games = schedule(d)

    entries =
      Enum.map(games, fn g ->
        %{
          "game_pk" => g[:game_pk],
          "venue" => g[:venue_name],
          "home" => %{
            "team_mlb_id" => g[:home_team_mlb_id],
            "team" => g[:home_team_name],
            "pitcher_mlb_id" => g[:home_probable_pitcher_mlb_id],
            "pitcher" => g[:home_probable_pitcher_name]
          },
          "away" => %{
            "team_mlb_id" => g[:away_team_mlb_id],
            "team" => g[:away_team_name],
            "pitcher_mlb_id" => g[:away_probable_pitcher_mlb_id],
            "pitcher" => g[:away_probable_pitcher_name]
          }
        }
      end)

    %{"date" => iso(d), "games" => entries}
  end

  @doc """
  For each hitter, find today's game for their team and the opposing probable
  starter, with season stats for both (spec §5.8).
  """
  @spec matchups_for_players([integer()], Date.t() | String.t() | nil) :: map()
  def matchups_for_players(ids, date) when is_list(ids) do
    d = to_date(date)
    games = schedule(d)
    matchups = ids |> cap_players() |> Enum.map(fn id -> build_matchup(id, d, games) end)
    %{"date" => iso(d), "matchups" => matchups}
  end

  # ── defensive input caps ──────────────────────────────────────────────────

  defp clamp_window(w) when is_integer(w), do: w |> max(1) |> min(@max_window_days)
  defp clamp_window(_), do: 30

  defp cap_players(ids) do
    ids |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.take(@max_players)
  end

  defp build_matchup(id, _date, games) do
    player = resolve_player(id)
    team_id = player && player.current_team_mlb_id

    game =
      team_id &&
        Enum.find(games, fn g ->
          g[:home_team_mlb_id] == team_id or g[:away_team_mlb_id] == team_id
        end)

    if is_nil(player) or is_nil(game) do
      %{"hitter" => hitter_block(player, id), "no_game" => true}
    else
      is_home = game[:home_team_mlb_id] == team_id

      opp_pitcher_id =
        if is_home,
          do: game[:away_probable_pitcher_mlb_id],
          else: game[:home_probable_pitcher_mlb_id]

      opp_pitcher_name =
        if is_home, do: game[:away_probable_pitcher_name], else: game[:home_probable_pitcher_name]

      %{
        "hitter" => Map.put(hitter_block(player, id), "season", season_stat_map(id, "hitting")),
        "opponent_pitcher" => %{
          "mlb_id" => opp_pitcher_id,
          "name" => opp_pitcher_name,
          "pitch_hand" => opp_pitcher_id && pitch_hand(opp_pitcher_id),
          "season" => (opp_pitcher_id && season_stat_map(opp_pitcher_id, "pitching")) || %{}
        },
        "venue" => game[:venue_name],
        "game_pk" => game[:game_pk]
      }
    end
  end

  defp hitter_block(nil, id), do: %{"mlb_id" => id, "name" => nil, "bat_side" => nil}

  defp hitter_block(player, _id),
    do: %{"mlb_id" => player.mlb_id, "name" => player.full_name, "bat_side" => player.bat_side}

  defp pitch_hand(id) do
    p = resolve_player(id)
    p && p.pitch_hand
  end

  defp season_stat_map(id, group) do
    player_stats(id, group: group)["stats"] || %{}
  end

  # ── persistence helpers ──────────────────────────────────────────────────

  defp upsert_game(g) do
    if g[:game_pk] do
      attrs =
        Map.take(g, [
          :game_pk,
          :game_date,
          :game_datetime,
          :game_type,
          :double_header,
          :game_number,
          :abstract_state,
          :detailed_state,
          :home_team_mlb_id,
          :away_team_mlb_id,
          :home_score,
          :away_score,
          :home_probable_pitcher_mlb_id,
          :away_probable_pitcher_mlb_id,
          :venue_mlb_id,
          :venue_name
        ])

      %Game{}
      |> Game.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :game_pk
      )

      upsert_probable(g[:home_probable_pitcher_mlb_id], g[:home_probable_pitcher_name])
      upsert_probable(g[:away_probable_pitcher_mlb_id], g[:away_probable_pitcher_name])
    end
  end

  defp upsert_probable(nil, _), do: :ok
  defp upsert_probable(id, name), do: upsert_player(%{mlb_id: id, full_name: name})

  defp upsert_player(%{mlb_id: nil}), do: :ok

  defp upsert_player(attrs) do
    attrs = Map.reject(attrs, fn {_k, v} -> is_nil(v) end)

    %Player{}
    |> Player.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :mlb_id
    )
  end

  defp persist_lines(%{home: home, away: away}, game_pk, game_date) do
    for side <- [home, away] do
      for line <- side.batting do
        line
        |> Map.merge(%{game_pk: game_pk, game_date: game_date})
        |> then(&(%BattingLine{} |> BattingLine.changeset(&1)))
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:game_pk, :player_mlb_id]
        )
      end

      for line <- side.pitching do
        line
        |> Map.merge(%{game_pk: game_pk, game_date: game_date})
        |> then(&(%PitchingLine{} |> PitchingLine.changeset(&1)))
        |> Repo.insert(
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:game_pk, :player_mlb_id]
        )
      end
    end
  end

  defp mark_box_ingested(game_pk, final?) do
    %BoxScore{}
    |> BoxScore.changeset(%{game_pk: game_pk, ingested_at: DateTime.utc_now(), final: final?})
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :game_pk
    )
  end

  defp upsert_home_run(hr, game) do
    upsert_player(%{mlb_id: hr[:batter_mlb_id], full_name: hr[:batter_name]})
    upsert_player(%{mlb_id: hr[:pitcher_mlb_id], full_name: hr[:pitcher_name]})

    {batter_team, pitcher_team} = hr_teams(hr, game)

    attrs = %{
      game_pk: game[:game_pk],
      game_date: game[:game_date],
      batter_mlb_id: hr[:batter_mlb_id],
      pitcher_mlb_id: hr[:pitcher_mlb_id],
      batter_team_mlb_id: batter_team,
      pitcher_team_mlb_id: pitcher_team,
      inning: hr[:inning],
      half_inning: hr[:half_inning],
      rbi: hr[:rbi],
      description: hr[:description],
      at_bat_index: hr[:at_bat_index]
    }

    %HomeRunEvent{}
    |> HomeRunEvent.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:game_pk, :at_bat_index]
    )
  end

  # top half = away batting; bottom half = home batting.
  defp hr_teams(%{half_inning: "top"}, game),
    do: {game[:away_team_mlb_id], game[:home_team_mlb_id]}

  defp hr_teams(_hr, game), do: {game[:home_team_mlb_id], game[:away_team_mlb_id]}

  # ── JSON shapers ─────────────────────────────────────────────────────────

  defp hr_json(%HomeRunEvent{} = h) do
    %{
      "batter" => person_ref(h.batter_mlb_id, h.batter_team_mlb_id),
      "pitcher" => person_ref(h.pitcher_mlb_id, h.pitcher_team_mlb_id),
      "inning" => h.inning,
      "half" => h.half_inning,
      "rbi" => h.rbi,
      "game_pk" => h.game_pk,
      "description" => h.description
    }
  end

  defp person_ref(nil, _team), do: %{"mlb_id" => nil, "name" => nil, "team" => nil}

  defp person_ref(id, team) do
    p = Repo.get_by(Player, mlb_id: id)
    %{"mlb_id" => id, "name" => p && p.full_name, "team" => team}
  end

  defp player_json(nil), do: nil

  defp player_json(p) do
    %{
      "mlb_id" => p.mlb_id,
      "name" => p.full_name,
      "position" => p.primary_position,
      "bat_side" => p.bat_side,
      "pitch_hand" => p.pitch_hand,
      "team_mlb_id" => p.current_team_mlb_id
    }
  end

  # Return the mirrored player. Players first seen via play-by-play carry no
  # current_team_mlb_id (the base /people response omits currentTeam), which
  # would make ensure_player_window/3 a no-op and yield games_scanned: 0. When
  # the team is missing, fetch /people/{id}?hydrate=currentTeam (cached) and
  # upsert so the streak window can be built.
  defp resolve_player(id) do
    case Repo.get_by(Player, mlb_id: id) do
      %Player{current_team_mlb_id: team} = player when not is_nil(team) -> player
      _ -> enrich_player(id)
    end
  end

  defp enrich_player(id) do
    query = %{"hydrate" => "currentTeam"}
    key = Map.put(query, "person_id", id)

    case Cache.fetch_or_fetch("person", key, fn ->
           Api.get("person", %{"person_id" => id}, query)
         end) do
      {:ok, body, _} ->
        case Parsers.parse_person(body) do
          %{mlb_id: mlb_id} = attrs when not is_nil(mlb_id) -> upsert_player(attrs)
          _ -> :ok
        end

      _ ->
        :ok
    end

    Repo.get_by(Player, mlb_id: id)
  end
end
