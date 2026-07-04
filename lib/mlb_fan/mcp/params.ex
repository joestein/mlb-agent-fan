defmodule MlbFan.Mcp.Params do
  @moduledoc """
  Trust-boundary input coercion + clamping for MCP tool inputs (spec §13,
  DoS/cost-runaway caps). Tool inputs come from the model and may be steered by
  prompt injection embedded in untrusted web content, so every numeric window
  and id-list is coerced to an integer and bounded here — before it can drive a
  per-day/per-player fetch fan-out in `MlbFan.Stats`.
  """

  # Defaults chosen per spec §8.2.9: 30 days comfortably covers any realistic
  # active streak; 60 is the hard ceiling. 25 players is well above any real
  # "who homered yesterday" slate.
  @default_window 30
  @min_window 1
  @max_window 60
  @max_ids 25

  @doc "Coerce a value to an integer, or nil if it cannot be parsed."
  @spec to_int(term()) :: integer() | nil
  def to_int(v) when is_integer(v), do: v

  def to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  def to_int(_), do: nil

  @doc """
  Clamp a model-supplied window value into `[min, max]`, defaulting when absent
  or unparseable. Guards against amplification (e.g. `window_days: 1_000_000`).
  """
  @spec window(term(), keyword()) :: pos_integer()
  def window(value, opts \\ []) do
    default = Keyword.get(opts, :default, @default_window)
    min = Keyword.get(opts, :min, @min_window)
    max = Keyword.get(opts, :max, @max_window)

    (to_int(value) || default)
    |> Kernel.max(min)
    |> Kernel.min(max)
  end

  @doc """
  Validate/dedupe/cap a list of integer ids at the trust boundary. Non-integer
  entries are dropped, order is preserved, duplicates removed, and the list is
  truncated to `cap` (default #{@max_ids}). Returns `{ids, truncated?}` so the
  caller can degrade gracefully with a note rather than a hard error.
  """
  @spec id_list(term(), pos_integer()) :: {[integer()], boolean()}
  def id_list(value, cap \\ @max_ids) do
    ids =
      value
      |> List.wrap()
      |> Enum.map(&to_int/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {Enum.take(ids, cap), length(ids) > cap}
  end

  @doc "Maximum number of player ids accepted per tool call."
  @spec max_ids() :: pos_integer()
  def max_ids, do: @max_ids

  @doc """
  Attach a human-readable truncation note to a tool result map when the input
  id-list was capped, so the note flows back to the model in the tool_result.
  """
  @spec maybe_note(map(), boolean(), String.t()) :: map()
  def maybe_note(result, false, _field), do: result

  def maybe_note(result, true, field) when is_map(result) do
    Map.put(
      result,
      "note",
      "#{field} was truncated to the first #{@max_ids} ids to bound fan-out; " <>
        "narrow the request if you need others."
    )
  end
end
