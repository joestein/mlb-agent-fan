# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mlb_fan,
  ecto_repos: [MlbFan.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# ── App defaults (overridable at runtime; NO secrets here) ────────────────
# Exa unit prices (USD) — string values parsed to Decimal at use.
config :mlb_fan, :exa_search_price_usd, "0.005"
config :mlb_fan, :exa_contents_price_usd, "0.001"
config :mlb_fan, :anthropic_model, "claude-opus-4-8"
# Soft per-session spend cap (USD, string→Decimal). Once a session's combined
# LLM + external-API cost reaches this, further LLM turns are refused (spec §13).
config :mlb_fan, :session_spend_cap_usd, "5.00"
# Exa search relevance type (per spec A2: "auto", configurable)
config :mlb_fan, :exa, type: "auto"
# Tool-loop / fan-out safety caps (spec §6.4 / §9 / §13)
config :mlb_fan, :agent,
  max_loop_iterations: 8,
  tool_concurrency: 8,
  tool_timeout_ms: 30_000,
  research_timeout_ms: 60_000

# Configure the endpoint
config :mlb_fan, MlbFanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MlbFanWeb.ErrorHTML, json: MlbFanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MlbFan.PubSub,
  live_view: [signing_salt: "C14p4cCN"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mlb_fan: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  mlb_fan: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
