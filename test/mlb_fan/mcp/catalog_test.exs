defmodule MlbFan.Mcp.CatalogTest do
  use ExUnit.Case, async: true

  alias MlbFan.Mcp.Catalog

  test "exposes exactly the 9 tools in stable order" do
    assert Catalog.tool_names() == [
             "get_schedule",
             "get_boxscore",
             "get_homers_by_date",
             "get_player_streaks",
             "lookup_player",
             "get_player_stats",
             "get_probable_pitchers",
             "get_matchups_for_players",
             "research_player_matchup"
           ]
  end

  test "anthropic_tools carry frozen name/description/input_schema" do
    tools = Catalog.anthropic_tools()
    assert length(tools) == 9

    streaks = Enum.find(tools, &(&1["name"] == "get_player_streaks"))

    assert streaks["input_schema"] == %{
             "type" => "object",
             "properties" => %{
               "player_mlb_ids" => %{
                 "type" => "array",
                 "items" => %{"type" => "integer"},
                 "description" => "MLB person ids."
               },
               "window_days" => %{
                 "type" => "integer",
                 "default" => 30,
                 "description" => "How many days of game logs to scan back."
               },
               "as_of_date" => %{
                 "type" => "string",
                 "description" =>
                   "ISO date; streak computed as of end of this day. Defaults to today."
               }
             },
             "required" => ["player_mlb_ids"]
           }
  end

  test "research_player_matchup requires hitter_name and pitcher_name" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "research_player_matchup"))
    assert tool["input_schema"]["required"] == ["hitter_name", "pitcher_name"]
  end

  test "every tool maps to a backing module implementing run/1" do
    for name <- Catalog.tool_names() do
      assert {:ok, module} = Catalog.module_for(name)
      Code.ensure_loaded!(module)
      assert function_exported?(module, :run, 1)
    end
  end

  # ── per-tool frozen input_schema spot-checks (spec §5) ───────────────────

  test "get_schedule schema matches spec §5.1" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "get_schedule"))

    assert tool["input_schema"]["type"] == "object"
    assert tool["input_schema"]["required"] == []
    assert get_in(tool, ["input_schema", "properties", "date", "type"]) == "string"
  end

  test "get_boxscore requires game_pk as an integer (spec §5.2)" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "get_boxscore"))

    assert tool["input_schema"]["required"] == ["game_pk"]
    assert get_in(tool, ["input_schema", "properties", "game_pk", "type"]) == "integer"
  end

  test "get_homers_by_date has no required fields, date is optional string (spec §5.3)" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "get_homers_by_date"))

    assert tool["input_schema"]["required"] == []
    assert get_in(tool, ["input_schema", "properties", "date", "type"]) == "string"
  end

  test "lookup_player requires name as a string (spec §5.5)" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "lookup_player"))

    assert tool["input_schema"]["required"] == ["name"]
    assert get_in(tool, ["input_schema", "properties", "name", "type"]) == "string"
  end

  test "get_player_stats requires player_mlb_id; group defaults to hitting (spec §5.6)" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "get_player_stats"))

    assert tool["input_schema"]["required"] == ["player_mlb_id"]

    assert get_in(tool, ["input_schema", "properties", "group", "enum"]) == [
             "hitting",
             "pitching"
           ]

    assert get_in(tool, ["input_schema", "properties", "group", "default"]) == "hitting"
  end

  test "get_matchups_for_players requires player_mlb_ids as array of integers (spec §5.8)" do
    tool = Enum.find(Catalog.anthropic_tools(), &(&1["name"] == "get_matchups_for_players"))

    assert tool["input_schema"]["required"] == ["player_mlb_ids"]
    assert get_in(tool, ["input_schema", "properties", "player_mlb_ids", "type"]) == "array"

    assert get_in(tool, ["input_schema", "properties", "player_mlb_ids", "items", "type"]) ==
             "integer"
  end

  test "every tool has a non-empty description string" do
    for tool <- Catalog.anthropic_tools() do
      assert is_binary(tool["description"]) and byte_size(tool["description"]) > 20,
             "#{tool["name"]} has a short or missing description"
    end
  end

  test "module_for/1 returns :error for unknown tool name" do
    assert :error = Catalog.module_for("no_such_tool")
  end

  test "fetch/1 returns the full tool definition including description and schema" do
    assert {:ok, tool} = Catalog.fetch("get_schedule")
    assert tool.name == "get_schedule"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
  end
end
