import Config

# All outbound HTTP in tests is routed through a Req.Test stub. Any request
# that is not explicitly stubbed raises, guaranteeing zero network egress.
config :mlb_fan, :req_plug, {Req.Test, MlbFan.ReqStub}

# Do not start the MCP server/client transports or the agent supervisors in
# tests; tool logic is exercised directly and via in-process dispatch.
config :mlb_fan, :start_mcp, false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mlb_fan, MlbFan.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # Defaults to 5432 (CI Postgres service + local native Postgres). Override with
  # DB_PORT to point at a non-default port.
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "mlb_fan_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mlb_fan, MlbFanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "WSq5Azum3e+XNB9O3tUtw8PhtL6ce0AgoX+abYfGhUQ94IrL4bXNTS2VExXhuZJ5",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
