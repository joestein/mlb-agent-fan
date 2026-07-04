defmodule MlbFan.Stats.Streaks do
  @moduledoc """
  Home-run and hitting streak computation from a player's per-game batting
  lines, implementing the precise rules and edge cases in spec §8.2.

  Streaks are over the player's **team games in chronological order** that the
  player appeared in, walking from the most recent backward:

    * Days off never break a streak (we count games, not calendar days).
    * Games the player did not appear in are skipped, not breakers.
    * Official walk/HBP/sac exception: a game with `at_bats == 0 and hits == 0`
      (hitting) / `at_bats == 0 and home_runs == 0` (HR) is *skipped*, neither
      extending nor breaking. A game with `≥1 AB` and no hit/HR *breaks* it.
    * Doubleheaders: each game is its own line and counts in order.
    * Window bound: only `window_days` are scanned; a streak that runs to the
      window edge sets `window_truncated: true` so callers can caveat.
  """

  @type line :: map() | struct()
  @type result :: %{
          hr_streak: non_neg_integer(),
          hitting_streak: non_neg_integer(),
          last_hr_date: Date.t() | nil,
          games_scanned: non_neg_integer(),
          window_truncated: boolean()
        }

  @doc "Compute streaks. `lines` may be in any order; they are sorted here."
  @spec compute([line()], keyword()) :: result()
  def compute(lines, _opts \\ []) do
    ordered = Enum.sort_by(lines, &sort_key/1)
    newest_first = Enum.reverse(ordered)

    {hr_streak, hr_broke} = walk(newest_first, &classify_hr/1)
    {hit_streak, hit_broke} = walk(newest_first, &classify_hit/1)

    appeared_games = Enum.count(newest_first, &appeared?/1)

    truncated =
      appeared_games > 0 and
        ((hr_streak > 0 and not hr_broke) or (hit_streak > 0 and not hit_broke))

    %{
      hr_streak: hr_streak,
      hitting_streak: hit_streak,
      last_hr_date: last_hr_date(ordered),
      games_scanned: appeared_games,
      window_truncated: truncated
    }
  end

  # ── walk (newest → oldest) ────────────────────────────────────────────────

  # Returns {streak_length, broke?} where broke? is true iff a game broke the
  # streak (as opposed to running out of games at the window boundary).
  defp walk([], _classify), do: {0, false}

  defp walk(games, classify), do: walk(games, classify, 0)

  defp walk([], _classify, count), do: {count, false}

  defp walk([g | rest], classify, count) do
    case classify.(g) do
      :extend -> walk(rest, classify, count + 1)
      :skip -> walk(rest, classify, count)
      :break -> {count, true}
    end
  end

  # ── classifiers ───────────────────────────────────────────────────────────

  defp classify_hr(g) do
    ab = field(g, :at_bats)
    hr = field(g, :home_runs)

    cond do
      not appeared?(g) -> :skip
      ab == 0 and hr == 0 -> :skip
      hr >= 1 -> :extend
      ab >= 1 and hr == 0 -> :break
      true -> :skip
    end
  end

  defp classify_hit(g) do
    ab = field(g, :at_bats)
    hits = field(g, :hits)

    cond do
      not appeared?(g) -> :skip
      ab == 0 and hits == 0 -> :skip
      hits >= 1 -> :extend
      ab >= 1 and hits == 0 -> :break
      true -> :skip
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp last_hr_date(ordered_asc) do
    ordered_asc
    |> Enum.filter(&(field(&1, :home_runs) >= 1))
    |> List.last()
    |> case do
      nil -> nil
      line -> field(line, :game_date)
    end
  end

  defp appeared?(g) do
    case field(g, :appeared) do
      true -> true
      false -> field(g, :plate_appearances) > 0 or field(g, :at_bats) > 0
      _ -> field(g, :plate_appearances) > 0 or field(g, :at_bats) > 0
    end
  end

  # Spec §8.2 rule 1/5: order by (game_date, game_number). Fall back to game_pk
  # only when game_number is absent (e.g. legacy rows), since a split/rescheduled
  # doubleheader can have game_pk order that disagrees with game_number order.
  defp sort_key(g),
    do: {field(g, :game_date), field(g, :game_number) || field(g, :game_pk) || 0}

  defp field(g, key) do
    value =
      cond do
        is_map(g) and Map.has_key?(g, key) -> Map.get(g, key)
        is_map(g) and Map.has_key?(g, to_string(key)) -> Map.get(g, to_string(key))
        true -> nil
      end

    default_for(key, value)
  end

  defp default_for(:game_date, v), do: v
  defp default_for(:appeared, v), do: v
  defp default_for(:game_pk, v), do: v
  # Keep nil so sort_key can fall back to game_pk when game_number is absent.
  defp default_for(:game_number, v), do: v
  defp default_for(_key, nil), do: 0
  defp default_for(_key, v), do: v
end
