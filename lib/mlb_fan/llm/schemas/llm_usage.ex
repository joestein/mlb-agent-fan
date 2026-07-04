defmodule MlbFan.Llm.Schemas.LlmUsage do
  @moduledoc "One row per Anthropic request (per loop turn) with token counts and computed USD cost."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "llm_usage" do
    field :session_id, :string
    field :message_id, :string
    field :question_label, :string
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_creation_input_tokens, :integer, default: 0
    field :cache_read_input_tokens, :integer, default: 0
    field :cost_usd, :decimal
    field :stop_reason, :string
    field :turn_index, :integer, default: 0

    timestamps()
  end

  @fields ~w(session_id message_id question_label model input_tokens output_tokens
             cache_creation_input_tokens cache_read_input_tokens cost_usd
             stop_reason turn_index)a

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, @fields)
    |> validate_required([:session_id, :model, :cost_usd])
  end
end
