defmodule MlbFan.Agent.AnswerCache do
  @moduledoc """
  Final-answer cache so a repeated daily default question is served at $0 after
  the first ask (spec §10.5). Keyed by `(question_key, for_date)`.
  """

  alias MlbFan.Mlb.Answers.AnswerCache, as: Schema
  alias MlbFan.Repo

  @doc "Fetch a cached answer for `{question_key, for_date}` or nil."
  @spec get({String.t(), Date.t()}) :: Schema.t() | nil
  def get({question_key, for_date}) do
    Repo.get_by(Schema, question_key: question_key, for_date: for_date)
  end

  @doc "Store/replace a cached answer."
  @spec put(String.t(), Date.t(), String.t(), Decimal.t()) ::
          {:ok, Schema.t()} | {:error, Ecto.Changeset.t()}
  def put(question_key, for_date, markdown, cost) do
    %Schema{}
    |> Schema.changeset(%{
      question_key: question_key,
      for_date: for_date,
      rendered_markdown: markdown,
      cost_usd: cost,
      built_at: DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:question_key, :for_date]
    )
  end
end
