defmodule MlbFan.CacheTest do
  use MlbFan.DataCase, async: true

  @moduletag :db

  alias MlbFan.Cache
  alias MlbFan.Cache.Keys
  alias MlbFan.Mlb.Schemas.RawResponse
  alias MlbFan.Repo

  defp counting_fun(body) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    fun = fn -> Agent.update(agent, &(&1 + 1)) && {:ok, body} end
    {agent, fun}
  end

  test "MISS populates the cache, second identical call is a HIT (fun not re-run)" do
    {agent, fun} = counting_fun(%{"dates" => []})

    assert {:ok, %{"dates" => []}, :miss} =
             Cache.fetch_or_fetch("schedule", %{"date" => "2026-07-02"}, fun)

    assert {:ok, %{"dates" => []}, :hit} =
             Cache.fetch_or_fetch("schedule", %{"date" => "2026-07-02"}, fun)

    assert Agent.get(agent, & &1) == 1
  end

  test "params-hash stability: different key order hits the same cached row" do
    {_agent, fun} = counting_fun(%{"ok" => true})
    Cache.fetch_or_fetch("schedule", %{"a" => 1, "b" => 2}, fun)

    assert {:ok, _, :hit} = Cache.fetch_or_fetch("schedule", %{"b" => 2, "a" => 1}, fun)
  end

  test "a stale TTL row is re-fetched" do
    hash = Keys.params_hash(%{"date" => "2026-07-02"})

    Repo.insert!(%RawResponse{
      endpoint: "schedule",
      params_hash: hash,
      body: %{"old" => true},
      status_code: 200,
      fetched_at: DateTime.add(DateTime.utc_now(), -3600, :second),
      ttl_seconds: 300,
      immutable: false
    })

    {agent, fun} = counting_fun(%{"fresh" => true})

    assert {:ok, %{"fresh" => true}, :miss} =
             Cache.fetch_or_fetch("schedule", %{"date" => "2026-07-02"}, fun)

    assert Agent.get(agent, & &1) == 1
  end

  test "an immutable (Final) row is always a HIT" do
    hash = Keys.params_hash(%{"game_pk" => 1})

    Repo.insert!(%RawResponse{
      endpoint: "boxscore",
      params_hash: hash,
      body: %{"final" => true},
      status_code: 200,
      fetched_at: DateTime.add(DateTime.utc_now(), -31_536_000, :second),
      ttl_seconds: nil,
      immutable: true
    })

    {agent, fun} = counting_fun(%{"should_not" => "run"})

    assert {:ok, %{"final" => true}, :hit} =
             Cache.fetch_or_fetch("boxscore", %{"game_pk" => 1}, fun)

    assert Agent.get(agent, & &1) == 0
  end

  test "a Final boxscore fetch is stored as immutable" do
    fun = fn -> {:ok, %{"final" => true}, %{immutable: true}} end
    Cache.fetch_or_fetch("boxscore", %{"game_pk" => 99}, fun)

    row = Cache.get_row("boxscore", Keys.params_hash(%{"game_pk" => 99}))
    assert row.immutable == true
    assert row.ttl_seconds == nil
  end
end
