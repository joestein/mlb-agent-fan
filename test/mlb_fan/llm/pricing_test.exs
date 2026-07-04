defmodule MlbFan.Llm.PricingTest do
  use ExUnit.Case, async: true

  alias MlbFan.Llm.Pricing

  test "opus-4-8 rates are $5 in / $25 out per MTok" do
    assert {Decimal.new("5.00"), Decimal.new("25.00")} == Pricing.rates("claude-opus-4-8")
  end

  test "unknown model falls back to opus-4-8" do
    assert Pricing.rates("mystery") == Pricing.rates("claude-opus-4-8")
  end

  test "cost for a 1M/1M/1M/1M token tuple on opus (in+out+write+read)" do
    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000
    }

    # 5 + 25 + (5*1.25)=6.25 + (5*0.10)=0.50 = 36.75
    assert Decimal.equal?(Pricing.cost("claude-opus-4-8", usage), Decimal.new("36.750000"))
  end

  test "cost is exact for a realistic Q1 tuple" do
    usage = %{input_tokens: 8_000, output_tokens: 1_200, cache_creation_input_tokens: 2_000}
    # 8000*5/1e6 + 1200*25/1e6 + 2000*6.25/1e6 = 0.04 + 0.03 + 0.0125 = 0.0825
    assert Decimal.equal?(Pricing.cost("claude-opus-4-8", usage), Decimal.new("0.082500"))
  end

  test "sonnet and haiku rates" do
    assert {Decimal.new("3.00"), Decimal.new("15.00")} == Pricing.rates("claude-sonnet-4-6")
    assert {Decimal.new("1.00"), Decimal.new("5.00")} == Pricing.rates("claude-haiku-4-5")
  end

  # ── Additional per-model cost formulas (spec §10.2) ───────────────────────

  test "cost for sonnet-4-6 with cache write and read gives correct exact decimal" do
    # sonnet: input=$3, output=$15, cache_write=$3*1.25=$3.75, cache_read=$3*0.10=$0.30
    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000
    }

    # 3 + 15 + 3.75 + 0.30 = 22.05
    assert Decimal.equal?(Pricing.cost("claude-sonnet-4-6", usage), Decimal.new("22.050000"))
  end

  test "cost for haiku-4-5 with cache write and read gives correct exact decimal" do
    # haiku: input=$1, output=$5, cache_write=$1*1.25=$1.25, cache_read=$1*0.10=$0.10
    usage = %{
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000
    }

    # 1 + 5 + 1.25 + 0.10 = 7.35
    assert Decimal.equal?(Pricing.cost("claude-haiku-4-5", usage), Decimal.new("7.350000"))
  end

  test "zero tokens gives zero cost" do
    usage = %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }

    assert Decimal.equal?(Pricing.cost("claude-opus-4-8", usage), Decimal.new(0))
  end

  test "missing token keys default to zero (partial usage map)" do
    # Only output_tokens supplied — input, cache fields default to 0
    usage = %{output_tokens: 1_000}
    # 0 + 1000*25/1e6 + 0 + 0 = 0.025
    assert Decimal.equal?(Pricing.cost("claude-opus-4-8", usage), Decimal.new("0.025000"))
  end

  test "cache write multiplier is exactly 1.25x the input rate" do
    # opus: input=$5, so cache_write = $5 * 1.25 = $6.25/MTok
    usage_input = %{input_tokens: 1_000_000}
    usage_write = %{cache_creation_input_tokens: 1_000_000}

    input_cost = Pricing.cost("claude-opus-4-8", usage_input)
    write_cost = Pricing.cost("claude-opus-4-8", usage_write)

    assert Decimal.equal?(write_cost, Decimal.mult(input_cost, Decimal.new("1.25")))
  end

  test "cache read multiplier is exactly 0.10x the input rate" do
    # opus: input=$5, so cache_read = $5 * 0.10 = $0.50/MTok
    usage_input = %{input_tokens: 1_000_000}
    usage_read = %{cache_read_input_tokens: 1_000_000}

    input_cost = Pricing.cost("claude-opus-4-8", usage_input)
    read_cost = Pricing.cost("claude-opus-4-8", usage_read)

    assert Decimal.equal?(read_cost, Decimal.mult(input_cost, Decimal.new("0.10")))
  end
end
