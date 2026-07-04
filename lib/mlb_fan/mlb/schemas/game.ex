defmodule MlbFan.Mlb.Schemas.Game do
  @moduledoc "Mirror of a scheduled/played MLB game (`gamePk` natural key)."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "games" do
    field :game_pk, :integer
    field :game_date, :date
    field :game_datetime, :utc_datetime_usec
    field :game_type, :string
    field :double_header, :string
    field :game_number, :integer
    field :abstract_state, :string
    field :detailed_state, :string
    field :home_team_mlb_id, :integer
    field :away_team_mlb_id, :integer
    field :home_score, :integer
    field :away_score, :integer
    field :home_probable_pitcher_mlb_id, :integer
    field :away_probable_pitcher_mlb_id, :integer
    field :venue_mlb_id, :integer
    field :venue_name, :string

    timestamps()
  end

  @fields ~w(game_pk game_date game_datetime game_type double_header game_number
             abstract_state detailed_state home_team_mlb_id away_team_mlb_id
             home_score away_score home_probable_pitcher_mlb_id
             away_probable_pitcher_mlb_id venue_mlb_id venue_name)a

  def changeset(game, attrs) do
    game
    |> cast(attrs, @fields)
    |> validate_required([:game_pk, :game_date])
    |> unique_constraint(:game_pk)
  end

  @doc "True once the game is Final (immutable thereafter)."
  def final?(%__MODULE__{abstract_state: "Final"}), do: true
  def final?(_), do: false
end
