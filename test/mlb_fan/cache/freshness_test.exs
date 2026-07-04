defmodule MlbFan.Cache.FreshnessTest do
  use ExUnit.Case, async: true

  alias MlbFan.Cache.Freshness
  alias MlbFan.Mlb.Schemas.RawResponse

  defp now, do: DateTime.utc_now()

  defp row(fields) do
    struct(
      RawResponse,
      Map.merge(
        %{
          immutable: false,
          fetched_at: now(),
          ttl_seconds: 300,
          params_json: %{},
          body: %{},
          endpoint: "schedule",
          params_hash: "x",
          status_code: 200
        },
        fields
      )
    )
  end

  # ── fresh?/2 ──────────────────────────────────────────────────────────────

  test "immutable row is always fresh regardless of how old it is" do
    ancient = DateTime.add(now(), -365 * 24 * 3600, :second)
    r = row(%{immutable: true, fetched_at: ancient, ttl_seconds: nil})
    assert Freshness.fresh?(r, now())
  end

  test "row with ttl_seconds=nil and immutable=false is stale (not a hit)" do
    # This edge case: ttl nil but NOT marked immutable → treat as stale
    r = row(%{immutable: false, ttl_seconds: nil, fetched_at: now()})
    refute Freshness.fresh?(r, now())
  end

  test "row with nil fetched_at is stale" do
    r = row(%{immutable: false, ttl_seconds: 300, fetched_at: nil})
    refute Freshness.fresh?(r, now())
  end

  test "row fetched 30 minutes ago with 1-hour TTL is still fresh" do
    fetched = DateTime.add(now(), -1800, :second)
    r = row(%{immutable: false, ttl_seconds: 3600, fetched_at: fetched})
    assert Freshness.fresh?(r, now())
  end

  test "row whose TTL expired is stale" do
    fetched = DateTime.add(now(), -3600, :second)
    r = row(%{immutable: false, ttl_seconds: 300, fetched_at: fetched})
    refute Freshness.fresh?(r, now())
  end

  test "stale? is the boolean inverse of fresh?" do
    r = row(%{immutable: true})
    assert Freshness.stale?(r, now()) == not Freshness.fresh?(r, now())

    r2 = row(%{immutable: false, ttl_seconds: nil})
    assert Freshness.stale?(r2, now()) == not Freshness.fresh?(r2, now())
  end

  # ── policy/2 ──────────────────────────────────────────────────────────────

  test "policy returns :immutable when entity_state is Final" do
    assert :immutable == Freshness.policy("boxscore", entity_state: "Final")
  end

  test "policy returns :immutable for boxscore with final?: true" do
    assert :immutable == Freshness.policy("boxscore", final?: true)
  end

  test "policy returns :immutable for playByPlay with final?: true" do
    assert :immutable == Freshness.policy("playByPlay", final?: true)
  end

  test "policy returns a short TTL for schedule endpoint" do
    assert {:ttl, ttl} = Freshness.policy("schedule")
    assert ttl > 0 and ttl <= 600
  end

  test "policy returns a long TTL for person endpoint" do
    assert {:ttl, ttl} = Freshness.policy("person")
    assert ttl >= 3600
  end

  test "policy returns a medium TTL for unknown endpoint" do
    assert {:ttl, _} = Freshness.policy("unknown_endpoint")
  end

  # ── to_row/1 ──────────────────────────────────────────────────────────────

  test "to_row converts :immutable to {nil, true}" do
    assert {nil, true} = Freshness.to_row(:immutable)
  end

  test "to_row converts {:ttl, n} to {n, false}" do
    assert {300, false} = Freshness.to_row({:ttl, 300})
    assert {86_400, false} = Freshness.to_row({:ttl, 86_400})
  end
end
