defmodule MlbFan.Cache.Freshness do
  @moduledoc """
  Per-endpoint TTL / immutability policy for the read-through cache.

  A completed ("Final") game's data never changes, so those responses are
  cached forever (`:immutable`). Schedules and other live-ish data get a short
  TTL so they refresh. See spec §4.8.
  """

  alias MlbFan.Mlb.Schemas.RawResponse

  # Short TTLs (seconds) for mutable endpoints.
  @schedule_ttl 300
  @default_ttl 900
  @stats_ttl 3_600
  @people_ttl 86_400

  @type policy :: :immutable | {:ttl, non_neg_integer()}

  @doc """
  Policy for an endpoint given optional entity state. When `entity_state` is
  `"Final"` the response is immutable.
  """
  @spec policy(String.t(), keyword()) :: policy()
  def policy(endpoint, opts \\ []) do
    cond do
      Keyword.get(opts, :entity_state) == "Final" -> :immutable
      endpoint in ~w(boxscore playByPlay) and Keyword.get(opts, :final?, false) -> :immutable
      endpoint == "schedule" -> {:ttl, @schedule_ttl}
      endpoint in ~w(person people_search) -> {:ttl, @people_ttl}
      endpoint == "player_stats" -> {:ttl, @stats_ttl}
      true -> {:ttl, @default_ttl}
    end
  end

  @doc "Convert a policy into `{ttl_seconds, immutable}` for persistence."
  @spec to_row(policy()) :: {non_neg_integer() | nil, boolean()}
  def to_row(:immutable), do: {nil, true}
  def to_row({:ttl, seconds}), do: {seconds, false}

  @doc """
  Is a cached row a HIT (still fresh) as of `now`? Immutable rows are always
  fresh; TTL rows are fresh while `fetched_at + ttl_seconds > now`.
  """
  @spec fresh?(RawResponse.t(), DateTime.t()) :: boolean()
  def fresh?(%RawResponse{immutable: true}, _now), do: true

  def fresh?(%RawResponse{fetched_at: nil}, _now), do: false

  def fresh?(%RawResponse{ttl_seconds: nil, immutable: false}, _now), do: false

  def fresh?(%RawResponse{fetched_at: fetched_at, ttl_seconds: ttl}, now) do
    DateTime.compare(DateTime.add(fetched_at, ttl, :second), now) == :gt
  end

  @spec stale?(RawResponse.t(), DateTime.t()) :: boolean()
  def stale?(row, now), do: not fresh?(row, now)
end
