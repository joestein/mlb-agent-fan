defmodule MlbFan.Mlb.Schemas.BoxScore do
  @moduledoc "Per-game marker that a box score has been ingested into the mirror."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "box_scores" do
    field :game_pk, :integer
    field :ingested_at, :utc_datetime_usec
    field :final, :boolean, default: false

    timestamps()
  end

  @fields ~w(game_pk ingested_at final)a

  def changeset(box, attrs) do
    box
    |> cast(attrs, @fields)
    |> validate_required([:game_pk])
    |> unique_constraint(:game_pk)
  end
end
