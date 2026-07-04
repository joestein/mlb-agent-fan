defmodule MlbFan.Mlb.Schemas.Player do
  @moduledoc "Mirror of an MLB person/player (`statsapi` person id is the natural key)."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "players" do
    field :mlb_id, :integer
    field :full_name, :string
    field :first_name, :string
    field :last_name, :string
    field :primary_position, :string
    field :bat_side, :string
    field :pitch_hand, :string
    field :current_team_mlb_id, :integer
    field :active, :boolean, default: true

    timestamps()
  end

  @fields ~w(mlb_id full_name first_name last_name primary_position bat_side
             pitch_hand current_team_mlb_id active)a

  def changeset(player, attrs) do
    player
    |> cast(attrs, @fields)
    |> validate_required([:mlb_id, :full_name])
    |> unique_constraint(:mlb_id)
  end
end
