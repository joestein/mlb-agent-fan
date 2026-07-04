defmodule MlbFan.Agent.ToolRouterTest do
  use MlbFan.DataCase, async: false

  @moduletag :db

  alias MlbFan.Agent.ToolRouter
  alias MlbFan.Repo
  alias MlbFan.Research.Schemas.ApiUsage, as: UsageRow
  alias MlbFan.TestFixtures

  # ── is_error path ─────────────────────────────────────────────────────────

  test "unknown tool name returns an is_error: true tool_result block" do
    blocks = [
      %{
        "type" => "tool_use",
        "id" => "toolu_bad",
        "name" => "nonexistent_tool",
        "input" => %{}
      }
    ]

    [result] = ToolRouter.run(blocks)

    assert result["type"] == "tool_result"
    assert result["tool_use_id"] == "toolu_bad"
    assert result["is_error"] == true
    assert is_binary(result["content"])
  end

  # ── parallel execution ────────────────────────────────────────────────────

  test "two parallel tool_use blocks both execute and return two tool_result blocks in one list" do
    TestFixtures.stub_statsapi(date: "2026-07-02")

    blocks = [
      %{
        "type" => "tool_use",
        "id" => "toolu_1",
        "name" => "get_schedule",
        "input" => %{"date" => "2026-07-02"}
      },
      %{
        "type" => "tool_use",
        "id" => "toolu_2",
        "name" => "get_schedule",
        "input" => %{"date" => "2026-07-03"}
      }
    ]

    results = ToolRouter.run(blocks)

    # Both blocks produce a result — ONE list, TWO entries (spec §6.4)
    assert length(results) == 2
    ids = Enum.map(results, & &1["tool_use_id"]) |> MapSet.new()
    assert MapSet.member?(ids, "toolu_1")
    assert MapSet.member?(ids, "toolu_2")
    assert Enum.all?(results, &(&1["type"] == "tool_result"))
    # Neither should be an error
    refute Enum.any?(results, &Map.get(&1, "is_error"))
  end

  test "each tool_result content is a JSON-encoded string" do
    TestFixtures.stub_statsapi(date: "2026-07-02")

    blocks = [
      %{
        "type" => "tool_use",
        "id" => "toolu_j",
        "name" => "get_schedule",
        "input" => %{"date" => "2026-07-02"}
      }
    ]

    [result] = ToolRouter.run(blocks)
    # content must be a JSON string (Anthropic tool_result requirement)
    assert is_binary(result["content"])
    assert {:ok, decoded} = Jason.decode(result["content"])
    assert is_map(decoded)
  end

  # ── mixed success + error ─────────────────────────────────────────────────

  test "a mix of valid and invalid tools returns one result per block with correct is_error flags" do
    TestFixtures.stub_statsapi(date: "2026-07-02")

    blocks = [
      %{
        "type" => "tool_use",
        "id" => "toolu_ok",
        "name" => "get_schedule",
        "input" => %{"date" => "2026-07-02"}
      },
      %{
        "type" => "tool_use",
        "id" => "toolu_err",
        "name" => "no_such_tool",
        "input" => %{}
      }
    ]

    results = ToolRouter.run(blocks)
    assert length(results) == 2

    ok_result = Enum.find(results, &(&1["tool_use_id"] == "toolu_ok"))
    err_result = Enum.find(results, &(&1["tool_use_id"] == "toolu_err"))

    refute ok_result["is_error"]
    assert err_result["is_error"] == true
  end

  # ── Exa session-cost attribution (spec §10 / G4) ──────────────────────────

  test "research_player_matchup routed with a session_id records api_usage attributed to that session" do
    # No Exa key in test config → no network call; the research fan-out still
    # records an api_usage row, and it must carry the session_id the router
    # injects (otherwise Exa spend is un-attributed and the spend cap sees $0).
    sid = "sess_#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "type" => "tool_use",
        "id" => "toolu_research",
        "name" => "research_player_matchup",
        "input" => %{
          "hitter_name" => "Aaron Judge",
          "pitcher_name" => "Brayan Bello",
          "venue" => "Yankee Stadium",
          "date" => "2026-07-02"
        }
      }
    ]

    [result] = ToolRouter.run(blocks, session_id: sid)

    assert result["type"] == "tool_result"
    refute result["is_error"]

    row = Repo.get_by(UsageRow, provider: "exa", session_id: sid)
    assert row
    refute is_nil(row.session_id)
    assert row.session_id == sid
  end

  # ── network egress guard ──────────────────────────────────────────────────

  test "an un-stubbed outbound HTTP request raises rather than hitting the real network" do
    # No Req.Test.stub installed for MlbFan.ReqStub.
    # MlbFan.Http.opts injects {Req.Test, MlbFan.ReqStub} in test config.
    # Req.Test raises RuntimeError when the stub name is not registered.
    assert_raise RuntimeError, ~r/MlbFan.ReqStub/, fn ->
      Req.post(MlbFan.Http.opts(url: "https://api.anthropic.com/v1/messages", json: %{}))
    end
  end
end
