defmodule MlbFan.Stats.StreaksTest do
  use ExUnit.Case, async: true

  alias MlbFan.Stats.Streaks

  # Build a game line map. Defaults describe an 0-for game the player appeared in.
  defp line(date, opts) do
    %{
      game_date: Date.from_iso8601!(date),
      game_pk: Keyword.get(opts, :pk, :erlang.phash2(date)),
      game_number: Keyword.get(opts, :gn),
      at_bats: Keyword.get(opts, :ab, 4),
      hits: Keyword.get(opts, :h, 0),
      home_runs: Keyword.get(opts, :hr, 0),
      plate_appearances: Keyword.get(opts, :pa, 4),
      appeared: Keyword.get(opts, :appeared, true)
    }
  end

  test "consecutive HR games build an HR streak; a 0-HR game breaks it" do
    lines = [
      line("2026-06-01", hr: 0, ab: 4, h: 1),
      line("2026-06-02", hr: 1, ab: 4, h: 2),
      line("2026-06-03", hr: 1, ab: 3, h: 1),
      line("2026-06-04", hr: 2, ab: 4, h: 2)
    ]

    r = Streaks.compute(lines, window_days: 30)
    assert r.hr_streak == 3
    assert r.hitting_streak == 4
    assert r.last_hr_date == ~D[2026-06-04]
  end

  test "days off (date gaps) do not break a streak" do
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 1),
      # 5 day gap — no games
      line("2026-06-07", hr: 1, ab: 4, h: 1),
      line("2026-06-08", hr: 1, ab: 4, h: 2)
    ]

    assert Streaks.compute(lines).hr_streak == 3
  end

  test "benched games (appeared? false) are skipped, not breakers" do
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 1),
      line("2026-06-02", appeared: false, ab: 0, pa: 0, h: 0, hr: 0),
      line("2026-06-03", hr: 1, ab: 4, h: 1)
    ]

    assert Streaks.compute(lines).hr_streak == 2
  end

  test "walk-only game (0 AB, 0 H) does not break the hitting streak (official rule)" do
    lines = [
      line("2026-06-01", ab: 4, h: 2, hr: 0),
      line("2026-06-02", ab: 0, h: 0, hr: 0, pa: 2),
      line("2026-06-03", ab: 4, h: 1, hr: 0)
    ]

    # The walk-only game is skipped (neither extends nor breaks), so the two
    # games with a hit remain a live 2-game streak spanning it.
    r = Streaks.compute(lines)
    assert r.hitting_streak == 2
  end

  test "a game with >=1 AB and 0 hits breaks the hitting streak" do
    lines = [
      line("2026-06-01", ab: 4, h: 1),
      line("2026-06-02", ab: 4, h: 0),
      line("2026-06-03", ab: 4, h: 2)
    ]

    assert Streaks.compute(lines).hitting_streak == 1
  end

  test "doubleheaders: both games count independently and in order" do
    lines = [
      line("2026-06-01", pk: 100, hr: 1, ab: 4, h: 1),
      line("2026-06-02", pk: 200, hr: 1, ab: 4, h: 1),
      line("2026-06-02", pk: 201, hr: 1, ab: 4, h: 2)
    ]

    assert Streaks.compute(lines).hr_streak == 3
  end

  test "split/rescheduled doubleheader orders by game_number, not game_pk (spec §8.2 rule 1/5)" do
    # A rescheduled DH where game_number order DISAGREES with game_pk order:
    # game 1 (the streak breaker) has a HIGHER pk than game 2 (a HR game).
    #   by game_number: [06-01 HR, 06-02#1 0-HR break, 06-02#2 HR] → newest HR
    #                    extends to 1, then the break stops it → hr_streak == 1
    #   by game_pk (WRONG): the pk-500 breaker sorts LAST (newest) → break first
    #                    → hr_streak == 0
    lines = [
      line("2026-06-01", pk: 100, gn: 1, hr: 1, ab: 4, h: 1),
      # Game 1 of the DH — a 0-HR game that breaks the HR streak; higher pk.
      line("2026-06-02", pk: 500, gn: 1, hr: 0, ab: 4, h: 1),
      # Game 2 of the DH — a HR game; lower pk than game 1.
      line("2026-06-02", pk: 400, gn: 2, hr: 1, ab: 4, h: 2)
    ]

    r = Streaks.compute(lines)
    # Respecting game_number: only the most-recent DH game (a HR) is on the
    # streak; the earlier DH game breaks it.
    assert r.hr_streak == 1
    assert r.last_hr_date == ~D[2026-06-02]

    # Guard: pk-only ordering would have produced 0 (proves ordering is by gn).
    pk_ordered = Enum.sort_by(lines, &{&1.game_date, &1.game_pk})
    assert List.last(pk_ordered).game_pk == 500
  end

  test "pinch-hit HR (1 AB) extends the HR streak; pinch-run (0 PA) is a skip" do
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 1),
      line("2026-06-02", ab: 0, pa: 0, h: 0, hr: 0, appeared: false),
      line("2026-06-03", hr: 1, ab: 1, h: 1, pa: 1)
    ]

    assert Streaks.compute(lines).hr_streak == 2
  end

  test "window truncation flag is set when the streak runs to the window edge" do
    lines = for d <- 1..5, do: line("2026-06-0#{d}", hr: 1, ab: 4, h: 1)
    r = Streaks.compute(lines, window_days: 5)
    assert r.hr_streak == 5
    assert r.window_truncated == true
  end

  test "a broken streak is not window_truncated" do
    # Oldest game breaks BOTH streaks (>=1 AB, 0 hits, 0 HR), so neither runs
    # to the window edge.
    lines = [
      line("2026-06-01", hr: 0, ab: 4, h: 0),
      line("2026-06-02", hr: 1, ab: 4, h: 1)
    ]

    r = Streaks.compute(lines)
    assert r.hr_streak == 1
    assert r.hitting_streak == 1
    assert r.window_truncated == false
  end

  test "empty data yields zero streaks and zero games scanned" do
    r = Streaks.compute([])
    assert r.hr_streak == 0
    assert r.hitting_streak == 0
    assert r.games_scanned == 0
    assert r.last_hr_date == nil
  end

  # ── additional spec §8.2 edge cases ───────────────────────────────────────

  test "walk-only game (0 AB, 0 HR) does NOT break the HR streak (same skip rule as hitting)" do
    # Rule 7: apply the same skip convention to HR streak — only walks, no AB.
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 2),
      line("2026-06-02", hr: 0, ab: 0, h: 0, pa: 2),
      line("2026-06-03", hr: 1, ab: 3, h: 1)
    ]

    r = Streaks.compute(lines)
    assert r.hr_streak == 2
    # The walk game has 0 AB, so the hitting streak also skips it — 2
    assert r.hitting_streak == 2
  end

  test "pinch-runner with appeared=true, 0 plate_appearances, 0 at-bats is skipped (spec §8.2 rule 8)" do
    # A PR who never came up to bat: appeared=true but pa=0, ab=0.
    # The classifier treats ab=0 + hr=0 as :skip, not as a streak-breaker.
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 2, appeared: true),
      # Pinch-runner: in the game but no plate appearance
      %{
        game_date: ~D[2026-06-02],
        game_pk: 999,
        appeared: true,
        at_bats: 0,
        plate_appearances: 0,
        hits: 0,
        home_runs: 0
      },
      line("2026-06-03", hr: 1, ab: 2, h: 1, appeared: true)
    ]

    r = Streaks.compute(lines)
    # The pinch-run game is skipped — the streak continues across it
    assert r.hr_streak == 2
  end

  test "only-Final games should be included; Live/Preview games break nothing (caller responsibility)" do
    # The compute/2 function is pure — it trusts the caller to supply only Final games.
    # Here we simulate correct behaviour: only two Final games provided.
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 2),
      line("2026-06-02", hr: 1, ab: 3, h: 1)
    ]

    r = Streaks.compute(lines)
    assert r.hr_streak == 2
    assert r.games_scanned == 2
  end

  test "consecutive hitting games then a 0-for-4 game: hitting streak is 1 (most recent)" do
    lines = [
      line("2026-06-01", ab: 4, h: 2, hr: 0),
      line("2026-06-02", ab: 4, h: 2, hr: 0),
      line("2026-06-03", ab: 4, h: 0, hr: 0),
      # Break — then a new 1-game streak
      line("2026-06-04", ab: 4, h: 1, hr: 0)
    ]

    assert Streaks.compute(lines).hitting_streak == 1
  end

  test "HR streak last_hr_date is the most recent game with a HR" do
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 2),
      line("2026-06-02", hr: 0, ab: 4, h: 0),
      line("2026-06-03", hr: 2, ab: 4, h: 3)
    ]

    r = Streaks.compute(lines)
    # Most recent HR game is June 3
    assert r.last_hr_date == ~D[2026-06-03]
    # Streak is 1 (June 2 had >=1 AB and 0 HR — break)
    assert r.hr_streak == 1
  end

  test "games_scanned counts only appeared games, not benched rows" do
    lines = [
      line("2026-06-01", hr: 1, ab: 4, h: 2),
      line("2026-06-02", appeared: false, ab: 0, pa: 0, h: 0, hr: 0),
      line("2026-06-03", hr: 1, ab: 4, h: 1)
    ]

    r = Streaks.compute(lines)
    # Only 2 appeared games
    assert r.games_scanned == 2
  end

  test "streak orders by real date across a month boundary (regression: Date structs mis-sorted)" do
    # Late-June 0-HR games then an early-July HR. If the sort key holds a raw
    # %Date{} it compares by Erlang term order (effectively day-of-month), so
    # July-03 (day 3) sorts before June-30 (day 30): the most recent game is
    # mistaken for June-30, the streak breaks there, and the July-03 HR is lost.
    lines = [
      line("2026-06-28", hr: 0, ab: 4, h: 1),
      line("2026-06-30", hr: 0, ab: 4, h: 0),
      line("2026-07-01", hr: 0, ab: 4, h: 0),
      line("2026-07-02", hr: 0, ab: 3, h: 0),
      line("2026-07-03", hr: 2, ab: 3, h: 2)
    ]

    r = Streaks.compute(lines, window_days: 30)
    assert r.hr_streak == 1
    assert r.hitting_streak == 1
    assert r.last_hr_date == ~D[2026-07-03]
  end

  test "a multi-game streak spanning a month boundary counts every game in date order" do
    lines = [
      line("2026-06-29", hr: 0, ab: 4, h: 0),
      line("2026-06-30", hr: 1, ab: 4, h: 1),
      line("2026-07-01", hr: 1, ab: 4, h: 2),
      line("2026-07-02", hr: 1, ab: 3, h: 1)
    ]

    r = Streaks.compute(lines, window_days: 30)
    assert r.hr_streak == 3
    assert r.last_hr_date == ~D[2026-07-02]
  end
end
