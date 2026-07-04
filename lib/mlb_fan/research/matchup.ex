defmodule MlbFan.Research.Matchup do
  @moduledoc """
  Per-hitter matchup research fan-out (spec §9). Builds 4 query angles and runs
  them in parallel through `MlbFan.Research.Exa`, dedups by domain, records Exa
  `api_usage`, and returns compact snippets (with source URLs) for Claude to
  synthesize a 1–10 confidence assessment. Claude calls this tool ONCE PER
  HITTER; those N calls run concurrently at the tool-router level, so worst-case
  concurrency is N × 4 Exa requests (each bounded here at 4).
  """

  require Logger

  alias MlbFan.Research.{ApiUsage, Exa}
  alias MlbFan.Stats

  @concurrency 4
  @per_angle 4
  @days_back 21
  @timeout 20_000

  @doc """
  Research a single hitter↔pitcher matchup. `args` keys: `:hitter_name`,
  `:hitter_mlb_id`, `:pitcher_name`, `:pitcher_mlb_id`, `:venue`, `:date`,
  optional `:session_id`.
  """
  @spec research(map()) :: map()
  def research(args) do
    hitter = args[:hitter_name] || args["hitter_name"]
    pitcher = args[:pitcher_name] || args["pitcher_name"]
    venue = args[:venue] || args["venue"] || ""
    date = args[:date] || args["date"] || Date.to_iso8601(Stats.today())
    side = bat_side(args[:hitter_mlb_id] || args["hitter_mlb_id"])
    session_id = args[:session_id] || args["session_id"]

    angles = build_angles(hitter, pitcher, venue, date, side)

    raw =
      angles
      |> Task.async_stream(
        fn {angle, query} ->
          {angle, Exa.search(query, num_results: @per_angle, days_back: @days_back)}
        end,
        max_concurrency: @concurrency,
        timeout: @timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    snippets =
      Enum.flat_map(raw, fn
        {:ok, {angle, {:ok, results}}} ->
          results |> Exa.dedup_by_domain(2) |> Enum.take(3) |> Enum.map(&snippet(&1, angle))

        _ ->
          []
      end)

    # Bill only angles that actually performed a network search: a `{:ok, _}`
    # outcome, and only when a key is configured (a no-key call returns
    # `{:ok, []}` without any request). Timed-out/killed and errored angles are
    # not counted (spec §10.3 — honest unit accounting).
    ApiUsage.record_exa(
      "search",
      searched_units(raw),
      %{hitter: hitter, pitcher: pitcher, date: date},
      session_id
    )

    %{"hitter" => hitter, "pitcher" => pitcher, "snippets" => snippets}
  end

  defp searched_units(raw) do
    if Exa.configured?() do
      Enum.count(raw, fn
        {:ok, {_angle, {:ok, _results}}} -> true
        _ -> false
      end)
    else
      0
    end
  end

  # Spec §9 angles A–D.
  defp build_angles(hitter, pitcher, venue, date, side) do
    year = String.slice(date, 0, 4)

    [
      {"recent_form", "#{hitter} recent home runs form last 2 weeks #{year}"},
      {"pitcher_hr_risk", "#{pitcher} home runs allowed vs #{side} HR/9 #{year}"},
      {"park_factor", "#{venue} home run park factor #{year}"},
      {"weather", "#{venue} weather forecast wind #{date} game"}
    ]
  end

  defp snippet(result, angle) do
    %{
      "angle" => angle,
      "title" => result.title,
      "url" => result.url,
      "text" => String.slice(result.text || "", 0, 1200),
      "published_date" => result.published_date
    }
  end

  # LHB / RHB from the hitter's bat side; switch hitters default to the pitcher-
  # dependent side left as "LHB" for query breadth.
  defp bat_side(nil), do: "RHB"

  defp bat_side(id) do
    case Stats.player_bat_side(id) do
      "L" -> "LHB"
      "R" -> "RHB"
      "S" -> "LHB"
      _ -> "RHB"
    end
  end
end
