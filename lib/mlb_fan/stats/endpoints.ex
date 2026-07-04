defmodule MlbFan.Stats.Endpoints do
  @moduledoc """
  ENDPOINTS registry — an Elixir port of the `MLB-StatsAPI` endpoint table.
  Maps a registry name to its URL template, allowed path/query params, and the
  required params. `MlbFan.Stats.Api` validates against this before any call so
  we never build request URLs from unvalidated free-text (spec §13 SSRF).
  """

  @base "https://statsapi.mlb.com/api/v1"

  @registry %{
    "schedule" => %{
      path: "/schedule",
      path_params: [],
      query_params: ~w(sportId date startDate endDate teamId hydrate),
      required: [],
      note: "Games for a date; hydrate probablePitcher,linescore,venue,team"
    },
    "boxscore" => %{
      path: "/game/{game_pk}/boxscore",
      path_params: ["game_pk"],
      query_params: [],
      required: ["game_pk"],
      note: "Per-player batting/pitching lines for one game"
    },
    "playByPlay" => %{
      path: "/game/{game_pk}/playByPlay",
      path_params: ["game_pk"],
      query_params: [],
      required: ["game_pk"],
      note: "All plays for a game — carries batter/pitcher HR attribution"
    },
    "person" => %{
      path: "/people/{person_id}",
      path_params: ["person_id"],
      query_params: ~w(hydrate),
      required: ["person_id"],
      note: "Single person bio"
    },
    "people_search" => %{
      path: "/people/search",
      path_params: [],
      query_params: ~w(names sportId),
      required: ["names"],
      note: "Player name search"
    },
    "player_stats" => %{
      path: "/people/{person_id}/stats",
      path_params: ["person_id"],
      query_params: ~w(stats group season),
      required: ["person_id"],
      note: "Season hitting/pitching stats"
    }
  }

  @spec base_url() :: String.t()
  def base_url, do: @base

  @spec registry() :: map()
  def registry, do: @registry

  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_endpoint}
  def fetch(name) do
    case Map.fetch(@registry, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :unknown_endpoint}
    end
  end
end
