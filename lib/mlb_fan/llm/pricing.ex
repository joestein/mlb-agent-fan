defmodule MlbFan.Llm.Pricing do
  @moduledoc """
  Anthropic pricing map (USD per 1M tokens) and the per-request cost formula
  (spec §10.1/§10.2). All math is `Decimal` — money is never a float.

  Cache multipliers (Anthropic standard): cache write = 1.25× input rate,
  cache read = 0.10× input rate.
  """

  @million Decimal.new(1_000_000)
  @cache_write_mult Decimal.new("1.25")
  @cache_read_mult Decimal.new("0.10")

  # model => {input_per_mtok, output_per_mtok}
  @prices %{
    "claude-opus-4-8" => {Decimal.new("5.00"), Decimal.new("25.00")},
    "claude-sonnet-4-6" => {Decimal.new("3.00"), Decimal.new("15.00")},
    "claude-haiku-4-5" => {Decimal.new("1.00"), Decimal.new("5.00")}
  }

  @default_model "claude-opus-4-8"

  @doc "Known models."
  @spec models() :: [String.t()]
  def models, do: Map.keys(@prices)

  @doc "Input/output per-MTok rates for a model (falls back to opus-4-8)."
  @spec rates(String.t()) :: {Decimal.t(), Decimal.t()}
  def rates(model), do: Map.get(@prices, model, @prices[@default_model])

  @doc """
  Cost in USD (Decimal, 6 dp) for a usage tuple. `usage` keys (any missing → 0):
  `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`,
  `:cache_read_input_tokens`.
  """
  @spec cost(String.t(), map()) :: Decimal.t()
  def cost(model, usage) do
    {input_rate, output_rate} = rates(model)

    input = tok(usage, :input_tokens)
    output = tok(usage, :output_tokens)
    cache_write = tok(usage, :cache_creation_input_tokens)
    cache_read = tok(usage, :cache_read_input_tokens)

    Decimal.new(0)
    |> Decimal.add(per_mtok(input, input_rate))
    |> Decimal.add(per_mtok(output, output_rate))
    |> Decimal.add(per_mtok(cache_write, Decimal.mult(input_rate, @cache_write_mult)))
    |> Decimal.add(per_mtok(cache_read, Decimal.mult(input_rate, @cache_read_mult)))
    |> Decimal.round(6)
  end

  defp per_mtok(tokens, rate) do
    tokens
    |> Decimal.new()
    |> Decimal.div(@million)
    |> Decimal.mult(rate)
  end

  defp tok(usage, key) do
    Map.get(usage, key) || Map.get(usage, to_string(key)) || 0
  end
end
