defmodule MlbFan.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # ── teams ──────────────────────────────────────────────────────────────
    create table(:teams) do
      add :mlb_id, :bigint, null: false
      add :name, :string
      add :abbreviation, :string
      add :team_code, :string
      add :league_name, :string
      add :division_name, :string
      add :venue_mlb_id, :bigint
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:mlb_id])

    # ── players ────────────────────────────────────────────────────────────
    create table(:players) do
      add :mlb_id, :bigint, null: false
      add :full_name, :string
      add :first_name, :string
      add :last_name, :string
      add :primary_position, :string
      add :bat_side, :string
      add :pitch_hand, :string
      add :current_team_mlb_id, :bigint
      add :active, :boolean, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:players, [:mlb_id])
    create index(:players, [:full_name])

    # ── games ──────────────────────────────────────────────────────────────
    create table(:games) do
      add :game_pk, :bigint, null: false
      add :game_date, :date
      add :game_datetime, :utc_datetime_usec
      add :game_type, :string
      add :double_header, :string
      add :game_number, :integer
      add :abstract_state, :string
      add :detailed_state, :string
      add :home_team_mlb_id, :bigint
      add :away_team_mlb_id, :bigint
      add :home_score, :integer
      add :away_score, :integer
      add :home_probable_pitcher_mlb_id, :bigint
      add :away_probable_pitcher_mlb_id, :bigint
      add :venue_mlb_id, :bigint
      add :venue_name, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:games, [:game_pk])
    create index(:games, [:game_date])
    create index(:games, [:home_team_mlb_id])
    create index(:games, [:away_team_mlb_id])

    # ── box_scores ─────────────────────────────────────────────────────────
    create table(:box_scores) do
      add :game_pk, :bigint, null: false
      add :ingested_at, :utc_datetime_usec
      add :final, :boolean, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:box_scores, [:game_pk])

    # ── batting_lines ──────────────────────────────────────────────────────
    create table(:batting_lines) do
      add :game_pk, :bigint, null: false
      add :game_date, :date
      add :player_mlb_id, :bigint, null: false
      add :team_mlb_id, :bigint
      add :batting_order, :integer
      add :plate_appearances, :integer, default: 0
      add :at_bats, :integer, default: 0
      add :hits, :integer, default: 0
      add :doubles, :integer, default: 0
      add :triples, :integer, default: 0
      add :home_runs, :integer, default: 0
      add :rbi, :integer, default: 0
      add :walks, :integer, default: 0
      add :strikeouts, :integer, default: 0
      add :appeared, :boolean, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:batting_lines, [:game_pk, :player_mlb_id])
    create index(:batting_lines, [:player_mlb_id, :game_date])

    # ── pitching_lines ─────────────────────────────────────────────────────
    create table(:pitching_lines) do
      add :game_pk, :bigint, null: false
      add :game_date, :date
      add :player_mlb_id, :bigint, null: false
      add :team_mlb_id, :bigint
      add :innings_pitched, :decimal
      add :outs, :integer, default: 0
      add :hits_allowed, :integer, default: 0
      add :runs, :integer, default: 0
      add :earned_runs, :integer, default: 0
      add :home_runs_allowed, :integer, default: 0
      add :walks, :integer, default: 0
      add :strikeouts, :integer, default: 0
      add :batters_faced, :integer, default: 0
      add :is_starter, :boolean, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pitching_lines, [:game_pk, :player_mlb_id])
    create index(:pitching_lines, [:player_mlb_id, :game_date])

    # ── home_run_events ────────────────────────────────────────────────────
    create table(:home_run_events) do
      add :game_pk, :bigint, null: false
      add :game_date, :date
      add :batter_mlb_id, :bigint
      add :pitcher_mlb_id, :bigint
      add :batter_team_mlb_id, :bigint
      add :pitcher_team_mlb_id, :bigint
      add :inning, :integer
      add :half_inning, :string
      add :rbi, :integer
      add :description, :text
      add :at_bat_index, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:home_run_events, [:game_pk, :at_bat_index])
    create index(:home_run_events, [:game_date])
    create index(:home_run_events, [:batter_mlb_id, :game_date])

    # ── raw_responses ──────────────────────────────────────────────────────
    create table(:raw_responses) do
      add :endpoint, :string, null: false
      add :params_hash, :string, null: false
      add :params_json, :map
      add :body, :map
      add :status_code, :integer
      add :fetched_at, :utc_datetime_usec
      add :ttl_seconds, :integer
      add :immutable, :boolean, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:raw_responses, [:endpoint, :params_hash])
    create index(:raw_responses, [:fetched_at])

    # ── llm_usage ──────────────────────────────────────────────────────────
    create table(:llm_usage) do
      add :session_id, :string
      add :message_id, :string
      add :question_label, :string
      add :model, :string
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :cache_creation_input_tokens, :integer, default: 0
      add :cache_read_input_tokens, :integer, default: 0
      add :cost_usd, :decimal
      add :stop_reason, :string
      add :turn_index, :integer, default: 0
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_usage, [:session_id])
    create index(:llm_usage, [:inserted_at])
    create index(:llm_usage, [:question_label])

    # ── api_usage ──────────────────────────────────────────────────────────
    create table(:api_usage) do
      add :session_id, :string
      add :provider, :string
      add :operation, :string
      add :units, :integer, default: 0
      add :cost_usd, :decimal
      add :meta, :map
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:api_usage, [:provider, :inserted_at])
    create index(:api_usage, [:session_id])

    # ── answer_cache ───────────────────────────────────────────────────────
    create table(:answer_cache) do
      add :question_key, :string, null: false
      add :for_date, :date, null: false
      add :input_hash, :string
      add :rendered_markdown, :text
      add :cost_usd, :decimal
      add :built_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:answer_cache, [:question_key, :for_date])
  end
end
