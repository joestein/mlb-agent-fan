defmodule MlbFan.TestFixtures do
  @moduledoc """
  Offline JSON fixtures + a `Req.Test` dispatcher for statsapi. Tests install the
  stub with `stub_statsapi/1`; any un-stubbed outbound request raises, keeping the
  suite fully offline (spec §12).
  """

  @doc "A `/schedule` body with a single Final game (default) for `date`."
  def schedule_body(opts \\ []) do
    date = Keyword.get(opts, :date, "2026-07-02")
    state = Keyword.get(opts, :state, "Final")

    %{
      "dates" => [
        %{
          "games" => [
            %{
              "gamePk" => 700_001,
              "officialDate" => date,
              "gameDate" => "#{date}T23:05:00Z",
              "gameType" => "R",
              "doubleHeader" => "N",
              "gameNumber" => 1,
              "status" => %{"abstractGameState" => state, "detailedState" => state},
              "teams" => %{
                "home" => %{
                  "team" => %{"id" => 147, "name" => "New York Yankees"},
                  "score" => 5,
                  "probablePitcher" => %{"id" => 543_037, "fullName" => "Gerrit Cole"}
                },
                "away" => %{
                  "team" => %{"id" => 111, "name" => "Boston Red Sox"},
                  "score" => 3,
                  "probablePitcher" => %{"id" => 605_483, "fullName" => "Brayan Bello"}
                }
              },
              "venue" => %{"id" => 3313, "name" => "Yankee Stadium"}
            }
          ]
        }
      ]
    }
  end

  @doc "A `/playByPlay` body with two home runs (one per team)."
  def playbyplay_body do
    %{
      "allPlays" => [
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
        },
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
      ]
    }
  end

  @doc "Install the statsapi dispatcher on the shared Req.Test stub."
  def stub_statsapi(opts \\ []) do
    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      cond do
        String.contains?(conn.request_path, "/schedule") ->
          Req.Test.json(conn, schedule_body(opts))

        String.contains?(conn.request_path, "/playByPlay") ->
          Req.Test.json(conn, playbyplay_body())

        String.contains?(conn.request_path, "/boxscore") ->
          Req.Test.json(conn, %{"teams" => %{"home" => %{}, "away" => %{}}})

        true ->
          Req.Test.json(conn, %{})
      end
    end)
  end
end
