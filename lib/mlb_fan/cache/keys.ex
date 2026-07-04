defmodule MlbFan.Cache.Keys do
  @moduledoc "Canonical cache key + params hash (sha256 of sorted params)."

  @doc """
  Stable sha256 hex of the params map, independent of key order or key
  string/atom-ness. Values are stringified so `1` and `"1"` hash identically.
  """
  @spec params_hash(map()) :: String.t()
  def params_hash(params) when is_map(params) do
    canonical =
      params
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical))
    |> Base.encode16(case: :lower)
  end

  @doc "Normalize params to a JSON-safe map with string keys (for `params_json`)."
  @spec normalize(map()) :: map()
  def normalize(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end
end
