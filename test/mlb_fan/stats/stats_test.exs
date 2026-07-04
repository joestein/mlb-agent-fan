defmodule MlbFan.StatsTest do
  use MlbFan.DataCase, async: true

  @moduletag :db

  import Ecto.Query

  alias MlbFan.Mlb.Schemas.{Game, HomeRunEvent, Player, RawResponse}
  alias MlbFan.Repo
  alias MlbFan.Stats
  alias MlbFan.TestFixtures

  test "homers_by_date fills the mirror from schedule + play-by-play and attributes the pitcher" do
    TestFixtures.stub_statsapi(date: "2026-07-02")

    result = Stats.homers_by_date("2026-07-02")

    assert result["date"] == "2026-07-02"
    assert result["count"] == 2

    judge = Enum.find(result["home_runs"], &(&1["batter"]["name"] == "Aaron Judge"))
    assert judge["pitcher"]["name"] == "Brayan Bello"
    assert judge["rbi"] == 2

    # Mirror populated: game + HR events persisted.
    assert Repo.get_by(Game, game_pk: 700_001)
    assert Repo.aggregate(from(h in HomeRunEvent), :count) == 2
  end

  test "a second identical homers_by_date call is served from the DB cache (no new HTTP)" do
    # First call fills cache via the stub.
    TestFixtures.stub_statsapi(date: "2026-07-02")
    Stats.homers_by_date("2026-07-02")

    # Replace the stub so any further outbound request would blow up the test.
    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 500), %{"error" => "should not be called"})
    end)

    result = Stats.homers_by_date("2026-07-02")
    assert result["count"] == 2

    # The schedule + playByPlay responses are cached.
    assert Repo.exists?(from r in RawResponse, where: r.endpoint == "schedule")
    assert Repo.exists?(from r in RawResponse, where: r.endpoint == "playByPlay")
  end

  test "a Live game's HRs are re-ingested (not frozen) once it goes Final with more HRs" do
    # First pass: the game is LIVE and only one HR has happened so far.
    stub_homers(state: "Live", plays: [judge_hr()])
    r1 = Stats.homers_by_date("2026-07-02")
    assert r1["count"] == 1

    # Later — the short-TTL schedule/playByPlay caches expire.
    Repo.delete_all(RawResponse)

    # Second pass: the SAME game is now FINAL with a SECOND HR added.
    stub_homers(state: "Final", plays: [judge_hr(), devers_hr()])
    r2 = Stats.homers_by_date("2026-07-02")

    # Gating the skip on finality (not on HomeRunEvent row existence) means the
    # not-yet-Final game is re-fetched, so the later HR is picked up. A
    # row-existence short-circuit would have frozen this at 1.
    assert r2["count"] == 2

    assert Repo.aggregate(from(h in HomeRunEvent, where: h.game_date == ^~D[2026-07-02]), :count) ==
             2
  end

  defp stub_homers(opts) do
    state = Keyword.fetch!(opts, :state)
    plays = Keyword.fetch!(opts, :plays)

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      cond do
        String.contains?(conn.request_path, "/schedule") ->
          Req.Test.json(conn, TestFixtures.schedule_body(date: "2026-07-02", state: state))

        String.contains?(conn.request_path, "/playByPlay") ->
          Req.Test.json(conn, %{"allPlays" => plays})

        true ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp judge_hr do
    %{
      "result" => %{
        "eventType" => "home_run",
        "rbi" => 2,
        "description" => "Aaron Judge homers (30) on a fly ball."
      },
      "about" => %{"inning" => 3, "halfInning" => "bottom", "atBatIndex" => 21},
      "matchup" => %{
        "batter" => %{"id" => 592_450, "fullName" => "Aaron Judge"},
        "pitcher" => %{"id" => 605_483, "fullName" => "Brayan Bello"}
      }
    }
  end

  defp devers_hr do
    %{
      "result" => %{
        "eventType" => "home_run",
        "rbi" => 1,
        "description" => "Rafael Devers homers (18)."
      },
      "about" => %{"inning" => 5, "halfInning" => "top", "atBatIndex" => 40},
      "matchup" => %{
        "batter" => %{"id" => 646_240, "fullName" => "Rafael Devers"},
        "pitcher" => %{"id" => 543_037, "fullName" => "Gerrit Cole"}
      }
    }
  end

  test "player_bat_side reads the mirror" do
    TestFixtures.stub_statsapi()
    Stats.homers_by_date("2026-07-02")
    # HR upserts create players with names but no bat side yet.
    assert Stats.player_bat_side(592_450) in [nil, "L", "R", "S"]
  end

  # ── DoS / cost-runaway caps (spec §13) ────────────────────────────────────

  test "player_streaks clamps an enormous window_days so schedule fan-out stays bounded" do
    # Seed a player with a team so ensure_player_window enters its per-day loop.
    Repo.insert!(
      Player.changeset(%Player{}, %{
        mlb_id: 111,
        full_name: "Clamp Test",
        current_team_mlb_id: 999
      })
    )

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      if String.contains?(conn.request_path, "/schedule"),
        do: Agent.update(counter, &(&1 + 1))

      Req.Test.json(conn, %{"dates" => []})
    end)

    # Without the clamp this would attempt ~1,000,001 schedule lookups.
    Stats.player_streaks([111], window_days: 1_000_000, as_of: "2026-07-02")

    # 60-day ceiling ⇒ 0..60 = 61 days scanned at most.
    assert Agent.get(counter, & &1) <= 61
  end

  test "player_streaks caps the number of players processed at 25" do
    Req.Test.stub(MlbFan.ReqStub, fn conn -> Req.Test.json(conn, %{"dates" => []}) end)

    ids = Enum.to_list(1..100)
    result = Stats.player_streaks(ids, window_days: 5, as_of: "2026-07-02")

    assert length(result["players"]) == 25
  end

  test "matchups_for_players caps the number of players processed at 25" do
    Req.Test.stub(MlbFan.ReqStub, fn conn -> Req.Test.json(conn, %{"dates" => []}) end)

    ids = Enum.to_list(1..100)
    result = Stats.matchups_for_players(ids, "2026-07-02")

    assert length(result["matchups"]) == 25
  end
end
