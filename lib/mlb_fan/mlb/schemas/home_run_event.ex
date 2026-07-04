defmodule MlbFan.Mlb.Schemas.HomeRunEvent do
  @moduledoc """
  One row per home run, with the pitcher who allowed it. Populated from
  play-by-play (`/game/:gamePk/playByPlay`), which — unlike the box score —
  carries batter↔pitcher attribution. Powers `get_homers_by_date`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "home_run_events" do
    field :game_pk, :integer
    field :game_date, :date
    field :batter_mlb_id, :integer
    field :pitcher_mlb_id, :integer
    field :batter_team_mlb_id, :integer
    field :pitcher_team_mlb_id, :integer
    field :inning, :integer
    field :half_inning, :string
    field :rbi, :integer
    field :description, :string
    field :at_bat_index, :integer

    timestamps()
  end

  @fields ~w(game_pk game_date batter_mlb_id pitcher_mlb_id batter_team_mlb_id
             pitcher_team_mlb_id inning half_inning rbi description at_bat_index)a

  def changeset(hr, attrs) do
    hr
    |> cast(attrs, @fields)
    |> validate_required([:game_pk, :game_date, :batter_mlb_id, :at_bat_index])
    |> unique_constraint([:game_pk, :at_bat_index])
  end
end
