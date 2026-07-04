defmodule MlbFan.Mcp.ParamsTest do
  use ExUnit.Case, async: true

  alias MlbFan.Mcp.Params

  # ── window clamping (DoS / cost-runaway cap, spec §13) ────────────────────

  test "an enormous window_days is clamped to the 60-day ceiling" do
    assert Params.window(1_000_000) == 60
    assert Params.window("1000000") == 60
  end

  test "zero and negative windows clamp up to 1" do
    assert Params.window(0) == 1
    assert Params.window(-5) == 1
    assert Params.window("-100") == 1
  end

  test "a nil / unparseable window falls back to the default (30)" do
    assert Params.window(nil) == 30
    assert Params.window("not-a-number") == 30
    assert Params.window(%{}) == 30
  end

  test "an in-range window passes through unchanged" do
    assert Params.window(14) == 14
    assert Params.window("7") == 7
  end

  # ── id-list validation / dedupe / cap ─────────────────────────────────────

  test "a list of 100 ids is truncated to the first 25 and flagged truncated" do
    ids = Enum.to_list(1..100)
    assert {kept, true} = Params.id_list(ids)
    assert length(kept) == 25
    assert kept == Enum.to_list(1..25)
  end

  test "a small id-list is preserved and not flagged truncated" do
    assert {[1, 2, 3], false} = Params.id_list([1, 2, 3])
  end

  test "non-integer entries are dropped and string ids coerced" do
    assert {[1, 2, 3], false} = Params.id_list([1, "2", "x", nil, 3])
  end

  test "duplicate ids are removed before capping" do
    assert {[1, 2], false} = Params.id_list([1, 1, 2, 2, 2])
  end

  test "a non-list value is wrapped" do
    assert {[7], false} = Params.id_list(7)
    assert {[], false} = Params.id_list(nil)
  end

  # ── truncation note ───────────────────────────────────────────────────────

  test "maybe_note adds a note only when truncated" do
    assert %{"a" => 1} == Params.maybe_note(%{"a" => 1}, false, "player_mlb_ids")

    noted = Params.maybe_note(%{"a" => 1}, true, "player_mlb_ids")
    assert noted["a"] == 1
    assert noted["note"] =~ "player_mlb_ids"
    assert noted["note"] =~ "25"
  end
end
