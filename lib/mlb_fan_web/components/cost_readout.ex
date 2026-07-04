defmodule MlbFanWeb.Components.CostReadout do
  @moduledoc "Function components for per-message and per-session cost badges (spec §10.6)."
  use Phoenix.Component

  attr :cost, :any, required: true
  attr :input, :integer, default: 0
  attr :output, :integer, default: 0
  attr :model, :string, default: "opus-4-8"
  attr :cached, :boolean, default: false

  @doc "Per-message cost badge, e.g. `$0.34 • 53.0K in / 3.0K out • opus-4-8`."
  def message_badge(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 text-xs text-zinc-500"
      title="Estimated cost for this answer"
    >
      <span class="font-mono">${fmt(@cost)}</span>
      <span>•</span>
      <span>{ktok(@input)} in / {ktok(@output)} out</span>
      <span>•</span>
      <span>{@model}</span>
      <span :if={@cached} class="text-emerald-600">• cached $0</span>
    </span>
    """
  end

  attr :cost, :any, required: true

  @doc "Per-session running total."
  def session_badge(assigns) do
    ~H"""
    <span class="text-sm font-medium text-zinc-700">Session: ${fmt(@cost)}</span>
    """
  end

  attr :projection, :map, required: true

  @doc "Daily/monthly projection widget with model what-if."
  def projection(assigns) do
    ~H"""
    <div class="text-xs text-zinc-500">
      If you run both default questions daily: ~${fmt(@projection.monthly_usd)}/mo on opus-4-8
      <span :if={@projection.what_if["claude-sonnet-4-6"]}>
        (sonnet ~${fmt(@projection.what_if["claude-sonnet-4-6"].monthly_usd)},
        haiku ~${fmt(@projection.what_if["claude-haiku-4-5"].monthly_usd)}).
      </span>
    </div>
    """
  end

  defp fmt(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2))
  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(_), do: "0.00"

  defp ktok(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}K"
  defp ktok(n) when is_integer(n), do: "#{n}"
  defp ktok(_), do: "0"
end
