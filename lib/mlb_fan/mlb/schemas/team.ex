defmodule MlbFan.Mlb.Schemas.Team do
  @moduledoc "Mirror of an MLB team (`statsapi` team id is the natural key)."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "teams" do
    field :mlb_id, :integer
    field :name, :string
    field :abbreviation, :string
    field :team_code, :string
    field :league_name, :string
    field :division_name, :string
    field :venue_mlb_id, :integer

    timestamps()
  end

  @fields ~w(mlb_id name abbreviation team_code league_name division_name venue_mlb_id)a

  def changeset(team, attrs) do
    team
    |> cast(attrs, @fields)
    |> validate_required([:mlb_id])
    |> unique_constraint(:mlb_id)
  end
end
