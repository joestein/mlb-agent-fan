# `mix test.unit` runs with `--no-start --exclude db`, so the Repo is not
# started; only configure the SQL sandbox when it is (full `mix test`).
ExUnit.start(exclude: [])

if Process.whereis(MlbFan.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(MlbFan.Repo, :manual)
end
