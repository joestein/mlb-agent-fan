defmodule MlbFan.Research.ApiUsage do
  @moduledoc "Records `api_usage` rows for external non-LLM APIs (Exa) with unit-based cost (spec §10.3)."

  import Ecto.Query

  alias MlbFan.Repo
  alias MlbFan.Research.Schemas.ApiUsage, as: Schema

  @doc """
  Record an Exa usage event. `operation` is `"search"` or `"contents"`; cost =
  `units × unit_price`. `meta` must never contain secrets (query text/params only).
  """
  @spec record_exa(String.t(), non_neg_integer(), map(), String.t() | nil) ::
          {:ok, Schema.t()} | {:error, Ecto.Changeset.t()}
  def record_exa(operation, units, meta \\ %{}, session_id \\ nil) do
    cost = Decimal.mult(unit_price(operation), Decimal.new(units))

    %Schema{}
    |> Schema.changeset(%{
      session_id: session_id,
      provider: "exa",
      operation: operation,
      units: units,
      cost_usd: cost,
      meta: meta
    })
    |> Repo.insert()
  end

  @doc "Total Exa (and other API) USD cost for a session."
  @spec session_total(String.t()) :: Decimal.t()
  def session_total(session_id) do
    Repo.one(
      from u in Schema, where: u.session_id == ^session_id, select: coalesce(sum(u.cost_usd), 0)
    )
    |> to_decimal()
  end

  defp unit_price("contents"), do: price(:exa_contents_price_usd, "0.001")
  defp unit_price(_search), do: price(:exa_search_price_usd, "0.005")

  defp price(key, default) do
    value = Application.get_env(:mlb_fan, key, default)
    Decimal.new(to_string(value))
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(n), do: Decimal.new(n)
end
