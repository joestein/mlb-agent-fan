defmodule MlbFan.Research.MatchupTest do
  use MlbFan.DataCase, async: false

  @moduletag :db

  alias MlbFan.Repo
  alias MlbFan.Research.Matchup
  alias MlbFan.Research.Schemas.ApiUsage, as: UsageRow

  setup do
    prev = Application.get_env(:mlb_fan, :exa)
    on_exit(fn -> Application.put_env(:mlb_fan, :exa, prev) end)
    :ok
  end

  test "records 0 Exa units when no API key is configured (no network call happens)" do
    # Default test config has no Exa key. `Exa.search/2` returns {:ok, []} with no
    # request, so nothing was actually searched — units must be 0, not length(angles).
    Application.put_env(:mlb_fan, :exa, type: "auto")

    sid = "sess_#{System.unique_integer([:positive])}"

    result =
      Matchup.research(%{
        hitter_name: "Aaron Judge",
        pitcher_name: "Brayan Bello",
        venue: "Yankee Stadium",
        date: "2026-07-02",
        session_id: sid
      })

    assert result["hitter"] == "Aaron Judge"
    assert result["snippets"] == []

    row = Repo.get_by(UsageRow, session_id: sid, provider: "exa")
    assert row
    # No network call was made for any angle → billed for 0 units at $0.
    assert row.units == 0
    assert Decimal.equal?(row.cost_usd, Decimal.new(0))
    # Session attribution still works even on the no-key path (spec §10 / G4).
    assert row.session_id == sid
  end

  test "counts every angle that performed a successful search when a key is configured" do
    Application.put_env(:mlb_fan, :exa, api_key: "test-exa-key", type: "auto")

    # Shared mode so the fan-out's async tasks reach this stub.
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      Req.Test.json(conn, %{
        "results" => [
          %{"title" => "hot", "url" => "https://mlb.com/a", "text" => "x", "publishedDate" => nil}
        ]
      })
    end)

    sid = "sess_#{System.unique_integer([:positive])}"

    Matchup.research(%{
      hitter_name: "Aaron Judge",
      pitcher_name: "Brayan Bello",
      venue: "Yankee Stadium",
      date: "2026-07-02",
      session_id: sid
    })

    row = Repo.get_by(UsageRow, session_id: sid, provider: "exa")
    assert row
    # All 4 spec §9 angles performed a network search.
    assert row.units == 4
    assert row.session_id == sid
  end
end
