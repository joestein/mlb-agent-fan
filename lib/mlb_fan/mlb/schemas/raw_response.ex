defmodule MlbFan.Mlb.Schemas.RawResponse do
  @moduledoc """
  Read-through cache of raw `statsapi` responses keyed by endpoint +
  sha256(params). A row is a HIT iff it is `immutable` (completed game) or
  `fetched_at + ttl_seconds` is still in the future; otherwise it is re-fetched.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]

  schema "raw_responses" do
    field :endpoint, :string
    field :params_hash, :string
    field :params_json, :map
    field :body, :map
    field :status_code, :integer
    field :fetched_at, :utc_datetime_usec
    field :ttl_seconds, :integer
    field :immutable, :boolean, default: false

    timestamps()
  end

  @fields ~w(endpoint params_hash params_json body status_code fetched_at ttl_seconds immutable)a

  def changeset(rr, attrs) do
    rr
    |> cast(attrs, @fields)
    |> validate_required([:endpoint, :params_hash, :fetched_at])
    |> unique_constraint([:endpoint, :params_hash])
  end
end
