defmodule MlbFan.Llm.CostTracker do
  @moduledoc """
  Persists `llm_usage` rows (one per Anthropic request/turn) and aggregates cost
  per message and per session (spec §10.6).
  """

  import Ecto.Query

  alias MlbFan.Llm.Pricing
  alias MlbFan.Llm.Schemas.LlmUsage
  alias MlbFan.Repo

  @doc """
  Record usage for one turn. `attrs` must include `:session_id` and `:model`;
  cost is computed from the token counts.
  """
  @spec record(map()) :: {:ok, LlmUsage.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    model = attrs[:model] || attrs["model"]
    cost = Pricing.cost(model, attrs)

    attrs
    |> Map.put(:cost_usd, cost)
    |> then(&LlmUsage.changeset(%LlmUsage{}, &1))
    |> Repo.insert()
  end

  @doc "Total USD cost for a session."
  @spec session_total(String.t()) :: Decimal.t()
  def session_total(session_id) do
    Repo.one(
      from u in LlmUsage, where: u.session_id == ^session_id, select: coalesce(sum(u.cost_usd), 0)
    )
    |> to_decimal()
  end

  @doc "Total USD cost for a single assistant message id (summed across loop turns)."
  @spec message_total(String.t()) :: Decimal.t()
  def message_total(message_id) do
    Repo.one(
      from u in LlmUsage, where: u.message_id == ^message_id, select: coalesce(sum(u.cost_usd), 0)
    )
    |> to_decimal()
  end

  @doc "Aggregate token counts for a message id (for the per-message badge)."
  @spec message_tokens(String.t()) :: %{input: integer(), output: integer()}
  def message_tokens(message_id) do
    row =
      Repo.one(
        from u in LlmUsage,
          where: u.message_id == ^message_id,
          select: %{
            input:
              coalesce(sum(u.input_tokens), 0) + coalesce(sum(u.cache_read_input_tokens), 0) +
                coalesce(sum(u.cache_creation_input_tokens), 0),
            output: coalesce(sum(u.output_tokens), 0)
          }
      )

    row || %{input: 0, output: 0}
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(n), do: Decimal.new(n)
end
