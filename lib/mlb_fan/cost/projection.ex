defmodule MlbFan.Cost.Projection do
  @moduledoc """
  Daily/monthly cost projection for running both default questions once per day
  (spec §10.4/§10.6). Uses observed per-label averages from `llm_usage` +
  `api_usage` once available, otherwise the spec's documented estimates. Also
  computes the cheaper-model "what-if" for the dashboard.
  """

  import Ecto.Query

  alias MlbFan.Llm.Schemas.LlmUsage
  alias MlbFan.Repo
  alias MlbFan.Research.Schemas.ApiUsage

  # Spec §10.4 estimates (opus-4-8), fallback until we have observed data.
  @estimate_q1 Decimal.new("0.09")
  @estimate_q2_llm Decimal.new("0.34")
  @estimate_q2_exa Decimal.new("0.36")

  # Rough model scaling factors vs opus for the LLM portion (Exa is model-independent).
  @model_llm_scale %{
    "claude-opus-4-8" => Decimal.new("1.0"),
    "claude-sonnet-4-6" => Decimal.new("0.6"),
    "claude-haiku-4-5" => Decimal.new("0.2")
  }

  @doc """
  Projection map: `%{daily_usd:, monthly_usd:, per_question:, what_if:}` for the
  configured (default opus-4-8) model, plus a model what-if breakdown.
  """
  @spec project() :: map()
  def project do
    q1 = observed_avg("hrs_yesterday") || @estimate_q1
    q2_llm = observed_avg("matchup_odds") || @estimate_q2_llm
    q2_exa = observed_exa_avg("matchup_odds") || @estimate_q2_exa

    q2 = Decimal.add(q2_llm, q2_exa)
    daily = Decimal.add(q1, q2)

    %{
      daily_usd: round2(daily),
      monthly_usd: round2(Decimal.mult(daily, 30)),
      per_question: %{"hrs_yesterday" => round2(q1), "matchup_odds" => round2(q2)},
      what_if: what_if(q1, q2_llm, q2_exa)
    }
  end

  defp what_if(q1, q2_llm, q2_exa) do
    Map.new(@model_llm_scale, fn {model, scale} ->
      day =
        q1
        |> Decimal.mult(scale)
        |> Decimal.add(Decimal.mult(q2_llm, scale))
        |> Decimal.add(q2_exa)

      {model, %{daily_usd: round2(day), monthly_usd: round2(Decimal.mult(day, 30))}}
    end)
  end

  # Average total LLM cost per assistant message for a question label.
  defp observed_avg(label) do
    Repo.all(
      from u in LlmUsage,
        where: u.question_label == ^label,
        group_by: u.message_id,
        select: sum(u.cost_usd)
    )
    |> average()
  end

  defp observed_exa_avg(_label) do
    rows =
      Repo.all(
        from u in ApiUsage,
          where: u.provider == "exa" and not is_nil(u.session_id),
          group_by: u.session_id,
          select: sum(u.cost_usd)
      )

    average(rows)
  end

  defp average([]), do: nil

  defp average(rows) do
    total = Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, to_dec(&1)))
    Decimal.div(total, Decimal.new(length(rows)))
  end

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(nil), do: Decimal.new(0)
  defp to_dec(n), do: Decimal.new(n)

  defp round2(%Decimal{} = d), do: Decimal.round(d, 2)
end
