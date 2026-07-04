defmodule MlbFan.Research.Schemas.ApiUsage do
  @moduledoc "One row per external non-LLM API call (Exa) with units and computed USD cost."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "api_usage" do
    field :session_id, :string
    field :provider, :string
    field :operation, :string
    field :units, :integer, default: 0
    field :cost_usd, :decimal
    field :meta, :map

    timestamps()
  end

  @fields ~w(session_id provider operation units cost_usd meta)a

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, @fields)
    |> validate_required([:provider, :operation, :cost_usd])
  end
end
