defmodule MlbFan.Mlb.Schemas.PitchingLine do
  @moduledoc "Per-player per-game pitching log. `outs` (= IP × 3) is the authoritative innings measure."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "pitching_lines" do
    field :game_pk, :integer
    field :game_date, :date
    field :player_mlb_id, :integer
    field :team_mlb_id, :integer
    field :innings_pitched, :decimal
    field :outs, :integer, default: 0
    field :hits_allowed, :integer, default: 0
    field :runs, :integer, default: 0
    field :earned_runs, :integer, default: 0
    field :home_runs_allowed, :integer, default: 0
    field :walks, :integer, default: 0
    field :strikeouts, :integer, default: 0
    field :batters_faced, :integer, default: 0
    field :is_starter, :boolean, default: false

    timestamps()
  end

  @fields ~w(game_pk game_date player_mlb_id team_mlb_id innings_pitched outs
             hits_allowed runs earned_runs home_runs_allowed walks strikeouts
             batters_faced is_starter)a

  def changeset(line, attrs) do
    line
    |> cast(attrs, @fields)
    |> validate_required([:game_pk, :game_date, :player_mlb_id])
    |> unique_constraint([:game_pk, :player_mlb_id])
  end
end
