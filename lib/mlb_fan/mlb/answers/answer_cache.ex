defmodule MlbFan.Mlb.Answers.AnswerCache do
  @moduledoc """
  Optional final-answer cache so a repeated daily default question is served
  at $0 after the first ask. Keyed by `(question_key, for_date)`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "answer_cache" do
    field :question_key, :string
    field :for_date, :date
    field :input_hash, :string
    field :rendered_markdown, :string
    field :cost_usd, :decimal
    field :built_at, :utc_datetime_usec

    timestamps()
  end

  @fields ~w(question_key for_date input_hash rendered_markdown cost_usd built_at)a

  def changeset(ac, attrs) do
    ac
    |> cast(attrs, @fields)
    |> validate_required([:question_key, :for_date, :rendered_markdown])
    |> unique_constraint([:question_key, :for_date])
  end
end
