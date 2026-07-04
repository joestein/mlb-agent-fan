defmodule MlbFan.Stats.ParsersTest do
  use ExUnit.Case, async: true

  alias MlbFan.Stats.Parsers
  alias MlbFan.TestFixtures

  test "parse_schedule extracts games with probable pitchers and status" do
    [game] = Parsers.parse_schedule(TestFixtures.schedule_body(date: "2026-07-02"))

    assert game.game_pk == 700_001
    assert game.game_date == ~D[2026-07-02]
    assert game.abstract_state == "Final"
    assert game.home_probable_pitcher_mlb_id == 543_037
    assert game.away_probable_pitcher_name == "Brayan Bello"
    assert game.venue_name == "Yankee Stadium"
  end

  test "parse_playbyplay_hrs keeps only home runs with batter/pitcher attribution" do
    hrs = Parsers.parse_playbyplay_hrs(TestFixtures.playbyplay_body())

    assert length(hrs) == 2
    judge = Enum.find(hrs, &(&1.batter_mlb_id == 592_450))
    assert judge.pitcher_name == "Brayan Bello"
    assert judge.half_inning == "bottom"
    assert judge.rbi == 2
  end

  test "ip_to_outs converts baseball innings notation" do
    assert Parsers.ip_to_outs("6.1") == 19
    assert Parsers.ip_to_outs("6.2") == 20
    assert Parsers.ip_to_outs("7.0") == 21
    assert Parsers.ip_to_outs(nil) == 0
  end

  test "parse_stats flattens the first season split" do
    body = %{"stats" => [%{"splits" => [%{"stat" => %{"homeRuns" => 30, "avg" => ".280"}}]}]}
    assert Parsers.parse_stats(body) == %{"homeRuns" => 30, "avg" => ".280"}
    assert Parsers.parse_stats(%{}) == %{}
  end
end
