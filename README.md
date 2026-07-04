# MLB Fan Agent

MLB Fan Agent is an Elixir/Phoenix application for **daily home-run betting research**. A Phoenix LiveView chat opens with the message `Welcome to MLB Fan Agent`, offers two default clickable questions, and streams answers token-by-token from Claude (`claude-opus-4-8`, adaptive thinking, prompt caching). Claude reaches all MLB data and Exa.ai web research exclusively through a Hermes MCP server (9 tools + 2 prompts). MLB stats are mirrored into Postgres as a DB-first read-through cache. Every request's Anthropic and Exa spend is tracked, shown per-message and per-session, and projected to daily/monthly totals.

**For research and entertainment only. No outcome is guaranteed; past streaks do not predict future results. Bet responsibly and within your means. If gambling is a problem, call 1-800-GAMBLER.**

---

## Architecture

```
Browser (Phoenix LiveView)
  "Welcome to MLB Fan Agent"
  [⚾ Who homered yesterday] [🎯 Who's pitching against them today]
  streaming tokens · per-message cost · session cost
         │ LiveView diffs (PubSub)          │ user event
         ▼                                  ▼
  MlbFanWeb.ChatLive  (LiveView, 1 per tab)
         │ GenServer.cast
         ▼
  MlbFan.Agent.Conversation  (GenServer, DynamicSupervisor)
    └─ Task → MlbFan.Agent.Loop (Anthropic tool-use loop, capped 8 iterations)
         │ POST /v1/messages (stream)               │ MCP tools/call
         ▼                                          ▼
  Anthropic API                        MlbFan.Mcp.Client
  api.anthropic.com                      (in-process by default)
  claude-opus-4-8                              │
  adaptive thinking                            ▼
  stream + prompt cache           MlbFan.Mcp.Server (Hermes, /mcp)
                                    9 tools + 2 prompts
                                         │ Stats tools          │ research_player_matchup
                                         ▼                       ▼
                                  MlbFan.Stats           MlbFan.Research.Matchup
                                  DB-first read-through   4-angle Exa fan-out
                                  cache facade            Task.async_stream
                                    │ HIT    │ MISS                │
                                    ▼        ▼                     ▼
                               Postgres 16  MlbFan.Stats.Api   api.exa.ai
                               mirror +     statsapi.mlb.com
                               raw cache    /api/v1
```

**Components:**

- `MlbFan.Stats` — Elixir port of MLB-StatsAPI (endpoints registry + Req) with a Postgres DB-first read-through cache. Mirrors games, box scores, batting/pitching lines, and home-run events. Computes HR and hitting streaks from the mirror.
- `MlbFan.Llm` — Raw-HTTP streaming Anthropic client, incremental SSE parser, pricing map, and per-turn cost tracker.
- `MlbFan.Mcp` — Hermes MCP server (Streamable HTTP, mounted at `/mcp`) with 9 tools + 2 prompts. The internal Jido agent uses in-process dispatch by default for reliability.
- `MlbFan.Agent` — A Jido agent whose `RunTurnAction` drives the Anthropic tool-use loop (`Loop`, `ToolRouter`, `Conversation`). Broadcasts text deltas over PubSub.
- `MlbFan.Research` — Exa.ai client + per-hitter 4-angle parallel matchup research with domain deduplication.
- `MlbFanWeb.ChatLive` — LiveView streaming chat with cost readout, autofocus, and the two default question buttons.

---

## Prerequisites

**Docker (recommended):**
- Docker Engine 24+ and Docker Compose v2

**Local development:**
- Elixir **1.17+** / OTP **26+** (developed on **1.18.4-otp-26**; see `.tool-versions`). The `hermes_mcp` and `jido` deps require Elixir ≥ 1.17.
- Postgres **16** (or run `docker compose up -d db` to get it)
- [asdf](https://asdf-vm.com/) (optional, for matching `.tool-versions`)

**API keys required:**
- Anthropic API key — [console.anthropic.com](https://console.anthropic.com)
- Exa.ai API key — [exa.ai](https://exa.ai)

---

## Quickstart with Docker Compose

```bash
# 1. Copy the example env file and open it in your editor.
cp .env.example .env

# 2. Fill in the three required secrets:
#    ANTHROPIC_API_KEY=sk-ant-...
#    EXA_API_KEY=...
#    SECRET_KEY_BASE=$(mix phx.gen.secret)  # or openssl rand -base64 48
#
#    Optional: set POSTGRES_PASSWORD to something other than the default "postgres".

# 3. Start the full stack (Postgres + Phoenix release).
docker compose up --build

# 4. Open http://localhost:4000
#    Click "⚾ Who homered yesterday — and their HR streaks"
#    When it finishes, click "🎯 Who's pitching against them today — and their chances"
```

Health check: `http://localhost:4000/health` returns 200.
MCP endpoint: `http://localhost:4000/mcp` (requires MCP `initialize` handshake before use).

---

## Local Development Quickstart

```bash
# Match the pinned toolchain (Elixir 1.18.4-otp-26):
asdf install

# Start Postgres only:
docker compose up -d db

# Install deps, create and migrate the DB, build assets:
mix setup

# Export keys (or put them in your shell profile):
export ANTHROPIC_API_KEY=sk-ant-...
export EXA_API_KEY=...

# Start the dev server with live reload:
mix phx.server
# → http://localhost:4000
```

---

## Running Tests

All outbound HTTP is stubbed with `Req.Test`; the suite runs fully offline.

```bash
# Full suite (needs Postgres — uses the test DB).
# Postgres can be started with: docker compose up -d db
mix test

# Fast, DB-free unit suite: streaks, pricing, SSE parser, parsers,
# cache keys, MCP catalog, Exa, tool router, prompts.
mix test.unit
```

166 tests, 0 failures (Elixir 1.18.4-otp-26 / Postgres 16).

---

## Environment Variables

| Variable | Description | Default | Required |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key | — | Yes |
| `EXA_API_KEY` | Exa.ai API key | — | Yes (without it, research returns empty snippets) |
| `SECRET_KEY_BASE` | Phoenix cookie signing key (`mix phx.gen.secret`) | — | Yes in prod |
| `DATABASE_URL` | Ecto DB URL (`ecto://user:pass@host/db`) | — | Yes in prod |
| `POSTGRES_PASSWORD` | Postgres password (docker-compose) | `postgres` | No |
| `ANTHROPIC_MODEL` | Override the LLM model | `claude-opus-4-8` | No |
| `SESSION_SPEND_CAP_USD` | Soft per-session spend ceiling (LLM + Exa); further turns refused when reached | `5.00` | No |
| `EXA_SEARCH_PRICE_USD` | Cost per Exa search (USD) | `0.005` | No |
| `EXA_CONTENTS_PRICE_USD` | Cost per Exa contents doc (USD) | `0.001` | No |
| `PORT` | HTTP listen port | `4000` | No |
| `PHX_HOST` | Public hostname (sets LiveView URL) | `localhost` | Prod |

Do not commit `.env` — it is git-ignored. Only `.env.example` (no secrets) is committed.

---

## The Two Default Questions

**Button 1 — "⚾ Who homered yesterday — and their HR streaks"**

Sends a user turn injecting today's date so the model knows "yesterday". Claude calls:
1. `get_homers_by_date` — lists every home run hit yesterday (batter, pitcher, team, inning, RBIs) by reading `home_run_events` from the DB (fills lazily from schedule + play-by-play on miss).
2. `get_player_streaks` — for each homer hitter, computes their current HR streak and hitting streak from `batting_lines` in the mirror.

The response is a markdown table sorted by HR streak descending, with a note on multi-HR games.

**Button 2 — "🎯 Who's pitching against them today — and their chances"**

Appears only after button 1 is answered. Claude calls:
1. `get_matchups_for_players` — pairs each hitter from yesterday with today's opposing probable starting pitcher and both players' season stats.
2. `research_player_matchup` once per hitter (calls run in parallel) — fans out 4 Exa queries (recent form, pitcher HR vulnerability, park factor, weather) and returns compact snippets with source URLs.

The response gives each hitter a 1–10 confidence score, 2–4 grounded bullets, cited sources, and a ranked table.

**Answer cache:** Each default question's final answer is stored in `answer_cache` keyed by `(question_key, date)`. Repeating the same default question on the same day returns the cached answer at $0 — no Anthropic call is made.

---

## Cost Model

| Model | Input / MTok | Output / MTok | Cache write | Cache read |
|---|---|---|---|---|
| claude-opus-4-8 (default) | $5.00 | $25.00 | $6.25 | $0.50 |
| claude-sonnet-4-6 | $3.00 | $15.00 | $3.75 | $0.30 |
| claude-haiku-4-5 | $1.00 | $5.00 | $1.25 | $0.10 |

Cache multipliers: write = 1.25× input rate, read = 0.10× input rate.

**Exa:** $0.005/search (default). The `research_player_matchup` tool fans out 4 searches per hitter; for ~18 hitters playing on a given day that is 72 searches ≈ $0.36.

**Estimated daily cost (both default questions, once per day, opus-4-8):**

| Question | Anthropic | Exa | Total |
|---|---|---|---|
| Q1 — HRs yesterday + streaks | ~$0.09 | $0 | ~$0.09 |
| Q2 — Matchups + research | ~$0.34 | ~$0.36 | ~$0.70 |
| **Both / day** | | | **~$0.79** |
| **Both / month** | | | **~$24** |

Same-day repeats of a default question cost $0 (served from `answer_cache`). The per-session cost readout and daily/monthly projection are shown in the UI. Set `SESSION_SPEND_CAP_USD` to limit a session's total spend; the default is $5.

---

## MCP Server

The Hermes MCP server is mounted at `/mcp` (Streamable HTTP). An external MCP client such as Claude Desktop can connect after the standard `initialize` handshake and then call `tools/list`, `tools/call`, `prompts/list`, and `prompts/get`.

**9 tools:**

| Tool | Purpose |
|---|---|
| `get_schedule` | MLB game schedule for a date |
| `get_boxscore` | Per-player batting/pitching lines for a game |
| `get_homers_by_date` | All HRs on a date with batter/pitcher/inning/RBI |
| `get_player_streaks` | HR streak + hitting streak for one or more players |
| `lookup_player` | Resolve a player name to their MLB person id |
| `get_player_stats` | Season hitting or pitching stats for a player |
| `get_probable_pitchers` | Probable starters for a date |
| `get_matchups_for_players` | Hitter → opposing probable pitcher pairs with stats |
| `research_player_matchup` | Exa web research for a hitter vs. pitcher matchup |

**2 prompts:**

| Prompt | Purpose |
|---|---|
| `hrs_yesterday_with_streaks` | Parameterized version of default question 1 |
| `matchup_odds_followup` | Parameterized version of default question 2 |

**Security note:** The `/mcp` endpoint is unauthenticated by design (single-user local research tool). Do not expose it on an untrusted network. The default Docker Compose configuration binds only to `localhost`.

---

## Security Notes

- **API keys** are loaded from environment variables only (`ANTHROPIC_API_KEY`, `EXA_API_KEY`). They are never logged, committed, or included in request logs.
- **Egress allowlist:** Outbound HTTP is restricted to `statsapi.mlb.com`, `api.anthropic.com`, and `api.exa.ai` at runtime by `MlbFan.Http`. Any future client that tries to reach another host will raise an `ArgumentError` before the request fires.
- **Markdown sanitization:** All assistant output is rendered through `Earmark` (`escape: true`) → `HtmlSanitizeEx.markdown_html` (allowlist scrubber) → non-`http(s)` href strip → `<img>` removal (alt text preserved). This prevents XSS and tracking-pixel egress from model-influenced content.
- **Input clamping:** `window_days` is clamped to `[1, 60]` and player ID lists are capped at 25 at the MCP tool boundary and again in `MlbFan.Stats`, preventing fan-out amplification from model-supplied values.
- **Spend cap:** `SESSION_SPEND_CAP_USD` (default $5) prevents a runaway session from accumulating unbounded Anthropic + Exa charges. The loop is also hard-capped at 8 iterations per turn.
- **SQL:** All queries use Ecto parameterized bindings; no string-built SQL.
- **Responsible gambling disclaimer:** The system prompt instructs Claude to end any betting-relevant answer with the disclaimer. `MlbFan.Agent.Prompts.ensure_disclaimer/1` re-appends it server-side as a safety net even if the model omits it.
- **Dependency advisory:** `earmark 1.4.49` carries a known advisory (GHSA-52mm-h59v-f3c7, stored XSS). It is mitigated by the downstream sanitizer chain and `mix deps.audit` exits 0 (advisory-only).

---

## Troubleshooting

**Off-season / empty schedules:** If `get_homers_by_date` returns `count: 0`, the MLB season may be over or the selected date had no games. The tool defaults to yesterday (Eastern time); try a specific date from the regular season.

**Missing API keys:** If `ANTHROPIC_API_KEY` is unset, the app starts but every chat turn returns `{:error, :no_api_key}`. If `EXA_API_KEY` is unset, `research_player_matchup` returns an empty `snippets` list and logs a warning — Q1 still works, Q2 produces answers without web research.

**Postgres connection refused:** Check that the DB container is healthy (`docker compose ps`) and that `DATABASE_URL` or the dev config (`config/dev.exs`) points to the right host/port. Run `mix ecto.migrate` if the migrations have not been applied.

**Elixir version mismatch:** `hermes_mcp` and `jido` require Elixir ≥ 1.17. If you see compile errors on those deps, run `asdf install` from the project root (`.tool-versions` pins 1.18.4-otp-26).
