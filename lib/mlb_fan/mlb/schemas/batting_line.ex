defmodule MlbFan.Mlb.Schemas.BattingLine do
  @moduledoc """
  Per-player per-game hitting log — the source of truth for streak
  computation (`MlbFan.Stats.Streaks`). `game_date` is denormalized so streak
  windows can be scanned without joining `games`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "batting_lines" do
    field :game_pk, :integer
    field :game_date, :date
    field :player_mlb_id, :integer
    field :team_mlb_id, :integer
    field :batting_order, :integer
    field :plate_appearances, :integer, default: 0
    field :at_bats, :integer, default: 0
    field :hits, :integer, default: 0
    field :doubles, :integer, default: 0
    field :triples, :integer, default: 0
    field :home_runs, :integer, default: 0
    field :rbi, :integer, default: 0
    field :walks, :integer, default: 0
    field :strikeouts, :integer, default: 0
    field :appeared, :boolean, default: false

    timestamps()
  end

  @fields ~w(game_pk game_date player_mlb_id team_mlb_id batting_order
             plate_appearances at_bats hits doubles triples home_runs rbi
             walks strikeouts appeared)a

  def changeset(line, attrs) do
    line
    |> cast(attrs, @fields)
    |> validate_required([:game_pk, :game_date, :player_mlb_id])
    |> unique_constraint([:game_pk, :player_mlb_id])
  end
end
