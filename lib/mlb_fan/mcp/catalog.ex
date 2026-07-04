defmodule MlbFan.Mcp.Catalog do
  @moduledoc """
  Single source of truth for the 9 MCP tools and their **frozen** JSON Schemas
  and descriptions (spec §5), used verbatim as the Anthropic `tools` array so
  prompt caching stays byte-stable and Claude sees exactly the contract in the
  spec. The Hermes MCP server registers functionally-equivalent components for
  external clients; these maps are authoritative for what the model receives.
  """

  alias MlbFan.Mcp.Tools

  @tools [
    %{
      name: "get_schedule",
      module: Tools.GetSchedule,
      description:
        "Get the MLB game schedule for a date, including teams, status, venue, and probable starting pitchers. Use to find which games are played on a given day.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "ISO date YYYY-MM-DD. Defaults to today (America/New_York)."
          }
        },
        "required" => []
      }
    },
    %{
      name: "get_boxscore",
      module: Tools.GetBoxscore,
      description:
        "Get the full box score for a single game by its gamePk: per-player batting and pitching lines for both teams.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "game_pk" => %{"type" => "integer", "description" => "MLB gamePk from the schedule."}
        },
        "required" => ["game_pk"]
      }
    },
    %{
      name: "get_homers_by_date",
      module: Tools.GetHomersByDate,
      description:
        "List every home run hit on a given date across MLB, with the batter, the pitcher who allowed it, the teams, inning, and RBIs. Use for 'who hit a home run yesterday'.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York)."
          }
        },
        "required" => []
      }
    },
    %{
      name: "get_player_streaks",
      module: Tools.GetPlayerStreaks,
      description:
        "For one or more players, compute their current home-run streak and hitting streak over the last N team games. HR streak = consecutive team games with at least one HR by the player. Hitting streak = consecutive games with at least one hit. Days off do not break a streak.",
      input_schema: %{
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
            "description" => "ISO date; streak computed as of end of this day. Defaults to today."
          }
        },
        "required" => ["player_mlb_ids"]
      }
    },
    %{
      name: "lookup_player",
      module: Tools.LookupPlayer,
      description:
        "Resolve a player name to their MLB person id and basic bio (position, bats/throws, team). Use before other tools when you only have a name.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Full or partial player name."}
        },
        "required" => ["name"]
      }
    },
    %{
      name: "get_player_stats",
      module: Tools.GetPlayerStats,
      description:
        "Get a player's season hitting or pitching stats for a given season and group.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "player_mlb_id" => %{"type" => "integer"},
          "group" => %{
            "type" => "string",
            "enum" => ["hitting", "pitching"],
            "default" => "hitting"
          },
          "season" => %{
            "type" => "integer",
            "description" => "4-digit year. Defaults to current season."
          }
        },
        "required" => ["player_mlb_id"]
      }
    },
    %{
      name: "get_probable_pitchers",
      module: Tools.GetProbablePitchers,
      description:
        "For a date, list each game's probable starting pitchers (home and away) with ids and hands. Use to find who a hitter's team faces today.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "date" => %{
            "type" => "string",
            "description" => "ISO date YYYY-MM-DD. Defaults to today."
          }
        },
        "required" => []
      }
    },
    %{
      name: "get_matchups_for_players",
      module: Tools.GetMatchupsForPlayers,
      description:
        "Given a list of hitters, find today's game for each hitter's team and the opposing probable starting pitcher. Returns hitter→opponent-pitcher pairs with basic stats for both.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "player_mlb_ids" => %{"type" => "array", "items" => %{"type" => "integer"}},
          "date" => %{
            "type" => "string",
            "description" => "ISO date YYYY-MM-DD. Defaults to today."
          }
        },
        "required" => ["player_mlb_ids"]
      }
    },
    %{
      name: "research_player_matchup",
      module: Tools.ResearchPlayerMatchup,
      description:
        "Deep web research for a single hitter-vs-pitcher matchup: recent form, the pitcher's HR vulnerability vs the hitter's handedness, ballpark HR factor, and weather/forecast. Returns compact research snippets with source URLs for the model to synthesize into a likelihood assessment. Call once per hitter; calls run in parallel.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "hitter_name" => %{"type" => "string"},
          "hitter_mlb_id" => %{"type" => "integer"},
          "pitcher_name" => %{"type" => "string"},
          "pitcher_mlb_id" => %{"type" => "integer"},
          "venue" => %{"type" => "string"},
          "date" => %{"type" => "string", "description" => "ISO date YYYY-MM-DD."}
        },
        "required" => ["hitter_name", "pitcher_name"]
      }
    }
  ]

  @by_name Map.new(@tools, &{&1.name, &1})

  @doc "All tool definitions."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Tool names in stable order."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tools, & &1.name)

  @doc "The Anthropic `tools` array (frozen name/description/input_schema, stable order)."
  @spec anthropic_tools() :: [map()]
  def anthropic_tools do
    Enum.map(@tools, fn t ->
      %{"name" => t.name, "description" => t.description, "input_schema" => t.input_schema}
    end)
  end

  @doc "Look up the backing module for a tool name."
  @spec module_for(String.t()) :: {:ok, module()} | :error
  def module_for(name) do
    case Map.fetch(@by_name, name) do
      {:ok, %{module: module}} -> {:ok, module}
      :error -> :error
    end
  end

  @doc "Look up a tool definition by name."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(name), do: Map.fetch(@by_name, name)
end
