defmodule MlbFan.Mcp.PromptsTest do
  use ExUnit.Case, async: true

  alias MlbFan.Mcp.Client
  alias MlbFan.Mcp.Prompts.{HrsYesterdayWithStreaks, MatchupOddsFollowup}

  # ── HrsYesterdayWithStreaks ───────────────────────────────────────────────

  test "hrs_yesterday text includes the provided date" do
    text = HrsYesterdayWithStreaks.text(%{"date" => "2026-07-02"})
    assert text =~ "2026-07-02"
  end

  test "hrs_yesterday text instructs using get_homers_by_date and get_player_streaks" do
    text = HrsYesterdayWithStreaks.text(%{"date" => "2026-07-02"})
    assert text =~ "get_homers_by_date"
    assert text =~ "get_player_streaks"
  end

  test "hrs_yesterday text requests a table sorted by HR streak descending" do
    text = HrsYesterdayWithStreaks.text(%{"date" => "2026-07-02"})
    assert text =~ "HR streak"
  end

  test "hrs_yesterday text also accepts atom-keyed args" do
    text = HrsYesterdayWithStreaks.text(%{date: "2026-07-03"})
    assert text =~ "2026-07-03"
  end

  test "hrs_yesterday text falls back to yesterday when no date given" do
    text = HrsYesterdayWithStreaks.text(%{})
    assert is_binary(text) and byte_size(text) > 50
  end

  # ── MatchupOddsFollowup ───────────────────────────────────────────────────

  test "matchup_odds text includes all provided player mlb ids" do
    text = MatchupOddsFollowup.text(%{"player_mlb_ids" => [592_450, 646_240]})
    assert text =~ "592450"
    assert text =~ "646240"
  end

  test "matchup_odds text instructs using get_matchups_for_players" do
    text = MatchupOddsFollowup.text(%{"player_mlb_ids" => [1]})
    assert text =~ "get_matchups_for_players"
  end

  test "matchup_odds text instructs calling research_player_matchup once per hitter" do
    text = MatchupOddsFollowup.text(%{"player_mlb_ids" => [1]})
    assert text =~ "research_player_matchup"
  end

  test "matchup_odds text requests a 1-10 confidence score and source citations" do
    text = MatchupOddsFollowup.text(%{"player_mlb_ids" => [1]})
    assert text =~ "1–10"
    assert text =~ "sources"
  end

  test "matchup_odds text also accepts atom-keyed args" do
    text = MatchupOddsFollowup.text(%{player_mlb_ids: [999]})
    assert text =~ "999"
  end

  test "matchup_odds text handles empty ids list without crash" do
    text = MatchupOddsFollowup.text(%{"player_mlb_ids" => []})
    assert is_binary(text)
  end

  # ── MlbFan.Mcp.Client.get_prompt/2 ───────────────────────────────────────

  test "Client.get_prompt hrs_yesterday_with_streaks returns ok with rendered text" do
    assert {:ok, text} =
             Client.get_prompt("hrs_yesterday_with_streaks", %{"date" => "2026-07-01"})

    assert text =~ "2026-07-01"
  end

  test "Client.get_prompt matchup_odds_followup returns ok with rendered text" do
    assert {:ok, text} =
             Client.get_prompt("matchup_odds_followup", %{"player_mlb_ids" => [592_450]})

    assert text =~ "592450"
  end

  test "Client.get_prompt unknown name returns an error tuple" do
    assert {:error, _reason} = Client.get_prompt("no_such_prompt", %{})
  end
end
