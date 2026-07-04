defmodule MlbFan.Repo do
  use Ecto.Repo,
    otp_app: :mlb_fan,
    adapter: Ecto.Adapters.Postgres
end
