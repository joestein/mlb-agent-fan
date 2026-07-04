defmodule MlbFan.Cache do
  @moduledoc """
  Read-through cache mechanics over `raw_responses`. `fetch_or_fetch/4` returns
  a cached body when fresh, otherwise runs `fun`, persists the result, and
  returns it. This is the single choke-point that makes every stats call
  DB-first (spec §1 G3 / §4.8).
  """

  import Ecto.Query
  require Logger

  alias MlbFan.Cache.{Freshness, Keys}
  alias MlbFan.Mlb.Schemas.RawResponse
  alias MlbFan.Repo

  @type fetch_fun :: (-> {:ok, map(), keyword()} | {:ok, map()} | {:error, term()})

  @doc """
  Look up `(endpoint, params)`; on a fresh HIT return `{:ok, body, :hit}`.
  On MISS/STALE, call `fun`, upsert, and return `{:ok, body, :miss}`.

  `fun` returns `{:ok, body}` or `{:ok, body, meta}` where `meta` may carry
  `:immutable` / `:entity_state` / `:status_code` used for the freshness policy.
  """
  @spec fetch_or_fetch(String.t(), map(), fetch_fun(), keyword()) ::
          {:ok, map(), :hit | :miss} | {:error, term()}
  def fetch_or_fetch(endpoint, params, fun, opts \\ []) do
    now = DateTime.utc_now()
    hash = Keys.params_hash(params)

    case get_row(endpoint, hash) do
      %RawResponse{} = row ->
        if Freshness.fresh?(row, now) do
          {:ok, row.body, :hit}
        else
          run_and_store(endpoint, params, hash, fun, opts, now)
        end

      nil ->
        run_and_store(endpoint, params, hash, fun, opts, now)
    end
  end

  @doc "Direct row lookup (used by tests and callers that need the metadata)."
  @spec get_row(String.t(), String.t()) :: RawResponse.t() | nil
  def get_row(endpoint, hash) do
    Repo.one(from r in RawResponse, where: r.endpoint == ^endpoint and r.params_hash == ^hash)
  end

  defp run_and_store(endpoint, params, hash, fun, opts, now) do
    case fun.() do
      {:ok, body} -> store(endpoint, params, hash, body, %{}, opts, now)
      {:ok, body, meta} -> store(endpoint, params, hash, body, Map.new(meta), opts, now)
      {:error, _} = err -> err
    end
  end

  defp store(endpoint, params, hash, body, meta, opts, now) do
    entity_state = Map.get(meta, :entity_state)

    policy_opts =
      Keyword.merge(opts, entity_state: entity_state, final?: Map.get(meta, :immutable, false))

    {ttl, immutable} = Freshness.policy(endpoint, policy_opts) |> Freshness.to_row()

    attrs = %{
      endpoint: endpoint,
      params_hash: hash,
      params_json: Keys.normalize(params),
      body: body,
      status_code: Map.get(meta, :status_code, 200),
      fetched_at: now,
      ttl_seconds: ttl,
      immutable: immutable
    }

    {:ok, _} =
      %RawResponse{}
      |> RawResponse.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:endpoint, :params_hash]
      )

    {:ok, body, :miss}
  end
end
