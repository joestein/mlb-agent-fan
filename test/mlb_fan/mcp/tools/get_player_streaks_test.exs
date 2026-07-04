defmodule MlbFan.Mcp.Tools.GetPlayerStreaksTest do
  use MlbFan.DataCase, async: true

  @moduletag :db

  alias MlbFan.Mcp.Tools.GetPlayerStreaks

  # No players are mirrored, so each id resolves to an empty streak with no
  # outbound fetch — this isolates the trust-boundary clamping behavior.

  test "more than 25 ids are truncated to 25 with a note in the result" do
    ids = Enum.to_list(1..100)

    result =
      GetPlayerStreaks.run(%{
        "player_mlb_ids" => ids,
        "window_days" => 5,
        "as_of_date" => "2026-07-02"
      })

    assert length(result["players"]) == 25
    assert result["note"] =~ "player_mlb_ids"
    assert result["note"] =~ "25"
  end

  test "25 or fewer ids produce no truncation note" do
    result =
      GetPlayerStreaks.run(%{
        "player_mlb_ids" => [1, 2, 3],
        "window_days" => 5,
        "as_of_date" => "2026-07-02"
      })

    refute Map.has_key?(result, "note")
    assert length(result["players"]) == 3
  end
end
