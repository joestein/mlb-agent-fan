# Specification: MLB Fan Agent

**Agent**: Architect (Staff Engineer, ISC2 security mindset)
**Session**: 20260703_143326_mlb-fan-agent
**Status**: Ready for implementation
**Worktree (code target)**: `/Users/charmalloc/dev/mlb-agent-fan/.claude/worktrees/mlb-fan-agent`

---

## 0. How to read this document

This is the sole input for the coding agent. It does **not** need the original user prompt. Every
section is concrete and load-bearing. Where an external library's API surface is uncertain
(`hermes_mcp`, `jido`), the spec says so explicitly and instructs the coding agent to verify via
`mix hex.docs` / the dep's source before wiring — see §15 Risks.

Reference project mined: `/Users/charmalloc/dev/sports-fanatic` (an existing Elixir/Phoenix MLB app).
Its Exa client, Anthropic client, and MLB Stats client are proven and their patterns are replicated
below with file citations. Key mined files:
- `lib/sports_fanatic/external_apis/exa.ex` — Exa client shape (retry, key config, URL-safety filter)
- `lib/sports_fanatic/ai/claude.ex` — Anthropic raw-HTTP client via Req (tool loop, key resolution)
- `lib/sports_fanatic/external_apis/mlb_stats.ex` — MLB Stats client (Req, throttle, parsers)
- `docker-compose.yml`, `Dockerfile`, `.env.example`, `config/runtime.exs` — infra/config patterns

---

## 1. Overview & Goals

### Summary
MLB Fan Agent is an Elixir/Phoenix application for **daily home-run betting research**. A Phoenix
LiveView chat opens with the assistant message `Welcome to MLB Fan Agent`, autofocuses the input, and
offers two default clickable questions. Answers stream token-by-token from Claude. Claude reaches MLB
data and Exa web research exclusively through an MCP server (tools + prompts). The MCP server is
backed by an Elixir port of the `MLB-StatsAPI` Python library, with **Postgres as a read-through
cache/mirror** of every stats call. A full per-request cost model records Anthropic and Exa spend and
projects daily/monthly cost.

### Product goals (verbatim user intent, mapped to features)
- **G1** — Default question #1: "everyone that got a HR the day before and what their current streak
  is of HR." → tool `get_homers_by_date` + `get_player_streaks`.
- **G2** — Default question #2 (appears after #1 is answered): "who from this list is pitching against
  whom and what are their chances of doing well based on the pitcher and hitter stats." → tools
  `get_matchups_for_players` + a fan-out of `research_player_matchup` (Exa) → Claude synthesis with a
  1–10 confidence score per player. Explicitly targets multi-HR / back-to-back-HR potential (e.g.
  Schwarber, Caminero, Judge).
- **G3** — Every stats query is DB-first: check Postgres, on miss call `statsapi.mlb.com`, persist,
  serve from DB. Streak questions ("7-day hitting streak", "HR streak") are computed from mirrored box
  scores.
- **G4** — Proper cost model: `llm_usage` + `api_usage` tables, per-message and per-session cost
  readout in the UI, daily/monthly projection, optional answer-caching so the daily default question
  is free after the first ask per day.
- **G5** — Ship-able: docker compose (postgres:16 + Phoenix mix release), `.env`-driven secrets.

### Non-goals for v1
See §"Out of Scope" at the end of this section.

### Architectural mandates (do NOT redesign away)
1. Elixir port of `MLB-StatsAPI` using the ENDPOINTS-registry pattern + high-level functions, via `Req`.
2. Postgres read-through cache/mirror for every stats query.
3. MCP **server** exposing tools **and** prompts via `hermes_mcp`.
4. **Jido** agent that connects to the MCP server **as an MCP client** for tool calls and prompts.
5. Phoenix LiveView streaming chat, autofocus, welcome string, two default question buttons, cost readout.
6. Anthropic via **raw HTTP (Req)** — model `claude-opus-4-8`, adaptive thinking, streaming, prompt
   caching, tool loop. Constraints in §6 are authoritative.
7. Cost model (§10).
8. Exa via raw HTTP (Req), patterns mined from sports-fanatic.
9. Docker compose + `.env.example`.

### Out of Scope (v1)
- User accounts / auth / multi-tenant (single-user local research tool; the chat has one anonymous
  session per browser tab). No login, no Stripe, no billing.
- Placing real bets or any sportsbook API integration. This is **research only**.
- Historical backfill beyond what queries touch (cache fills lazily; an optional warmer is nice-to-have).
- Non-MLB sports.
- Baseball Savant / Statcast ingestion (pitcher/hitter season splits from statsapi are sufficient for v1;
  Statcast is a documented future enhancement).
- Redis/Valkey (Postgres is the only datastore; sports-fanatic's Valkey is not ported).
- Python bridge (fully native Elixir; the sports-fanatic python_bridge is NOT ported).

---

## 2. System Architecture (ASCII)

```
                          ┌──────────────────────────────────────────────────────────────┐
                          │                    Browser (Phoenix LiveView)                 │
                          │  "Welcome to MLB Fan Agent"  • autofocused input              │
                          │  [Btn1: HRs yesterday + streaks] [Btn2: matchups & odds]      │
                          │  streaming tokens • per-msg cost • per-session cost            │
                          └───────────────▲───────────────────────────┬──────────────────┘
                                          │ LiveView diffs (PubSub)    │ user event
                                          │ (SSE deltas relayed)       ▼
                          ┌───────────────┴───────────────────────────────────────────────┐
                          │  MlbFanWeb.ChatLive  (LiveView process, 1 per session)         │
                          │  - renders messages, buttons, cost                             │
                          │  - starts ChatSession GenServer / Jido agent, subscribes PubSub│
                          └───────────────┬───────────────────────────────────────────────┘
                                          │ cast: user turn
                                          ▼
   ┌───────────────────────────────────────────────────────────────────────────────────────────┐
   │  MlbFan.Agent  (Jido agent + orchestration GenServer)                                       │
   │  Anthropic tool-use loop:                                                                    │
   │   1. POST /v1/messages (stream:true) with system+tools (cache_control), messages            │
   │   2. parse SSE → broadcast text deltas to LiveView via PubSub                                │
   │   3. on stop_reason=tool_use → run ALL tool_use blocks via MCP client                        │
   │   4. return ALL tool_result blocks in ONE user message → loop to (1)                         │
   │   5. record usage → MlbFan.Llm.CostTracker (llm_usage)                                       │
   └───────┬───────────────────────────────────────────────────────────┬─────────────────────────┘
           │ tools/call, prompts/get (MCP client)                       │ HTTPS stream (Req)
           ▼                                                            ▼
   ┌────────────────────────────┐                          ┌──────────────────────────────────────┐
   │ MlbFan.Mcp.Client          │  Streamable HTTP (MCP)   │  Anthropic API                        │
   │ (hermes_mcp client)        │◄────────────────────────►│  POST api.anthropic.com/v1/messages   │
   └───────────┬────────────────┘                          │  model: claude-opus-4-8               │
               │ in-proc (same BEAM node) or HTTP           └──────────────────────────────────────┘
               ▼
   ┌────────────────────────────────────────────────────────────────────────────────────────────┐
   │ MlbFan.Mcp.Server  (hermes_mcp server; Streamable HTTP transport)                            │
   │ Tools: get_schedule, get_boxscore, get_homers_by_date, get_player_streaks, lookup_player,    │
   │        get_player_stats, get_probable_pitchers, get_matchups_for_players, research_player_matchup│
   │ Prompts: hrs_yesterday_with_streaks, matchup_odds_followup                                    │
   └───────┬───────────────────────────────────────────────────────────────┬──────────────────────┘
           │ calls Stats context                                            │ calls Research context
           ▼                                                                ▼
   ┌────────────────────────────────────────────┐              ┌──────────────────────────────────┐
   │ MlbFan.Stats  (facade over cache+API port)  │              │ MlbFan.Research (Exa)             │
   │  schedule/boxscore/streaks/players/leaders  │              │  Task.async_stream fan-out        │
   │  ── DB-first read-through ──                 │              │  → api.exa.ai /search /contents   │
   └───────┬───────────────────────┬─────────────┘              └───────────────┬──────────────────┘
           │ HIT                    │ MISS → fetch → persist                     │ HTTPS (Req)
           ▼                        ▼                                            ▼
   ┌───────────────────┐   ┌──────────────────────────────┐          ┌──────────────────────────┐
   │  Postgres 16      │   │ MlbFan.Stats.Api (port)      │          │  api.exa.ai              │
   │  mirror + raw     │◄──│  ENDPOINTS registry + Req    │─────────►│                          │
   │  cache tables     │   │  statsapi.mlb.com /api/v1    │          └──────────────────────────┘
   └───────────────────┘   │  (v1.1 for /feed/live)       │
                           └──────────────────────────────┘
```

**Two viable MCP wirings** (coding agent picks based on `hermes_mcp` capabilities — see §15 R1):
- **(A) In-process/same-node**: MCP server and client run in the same BEAM app; simplest deploy. The
  Jido agent's MCP client talks to the local Hermes server over Streamable HTTP on `127.0.0.1` (or an
  in-proc transport if `hermes_mcp` provides one).
- **(B) Separate transport**: Hermes server mounted in the Phoenix router at `/mcp` (Streamable HTTP);
  client connects via URL. Preferred for the "expose as tools AND prompts to external MCP clients too"
  goal. **Default to (B)**: mount the server on the Phoenix endpoint so an external MCP client (e.g.
  Claude Desktop) could also connect, and have the internal Jido client point at `http://localhost:4000/mcp`.

---

## 3. Elixir App Layout (module tree, one-line responsibilities)

Single Phoenix 1.8 umbrella-less app named `MlbFan` (web module `MlbFanWeb`).

```
lib/
├── mlb_fan/
│   ├── application.ex                 # OTP tree: Repo, PubSub, Endpoint, MCP server, MCP client, Finch/Req pool, cost cache
│   ├── repo.ex                        # Ecto.Repo (Postgres)
│   │
│   ├── stats/                         # ── CONTEXT: MLB-StatsAPI port + read-through cache facade ──
│   │   ├── stats.ex                   # MlbFan.Stats public facade: schedule/2, boxscore/1, homers_by_date/1,
│   │   │                              #   player_streaks/2, lookup_player/1, player_stats/2, probable_pitchers/1,
│   │   │                              #   matchups_for_players/2, league_leaders/2 — ALL DB-first read-through
│   │   ├── api.ex                     # MlbFan.Stats.Api: get(endpoint, path_params, query_params) → Req call w/ registry validation
│   │   ├── endpoints.ex               # ENDPOINTS registry: name → %{url, path_params, query_params, required, note}
│   │   ├── parsers.ex                 # Pure functions: parse_schedule/1, parse_boxscore/1, parse_playbyplay_hrs/1, parse_person/1, parse_stats/1
│   │   └── streaks.ex                 # MlbFan.Stats.Streaks: compute HR streak + hitting streak from mirrored game logs
│   │
│   ├── cache/                         # ── CONTEXT: read-through cache mechanics ──
│   │   ├── cache.ex                   # fetch_or_fetch(endpoint, params, fun): raw-response cache lookup by key+hash, TTL/freshness policy
│   │   ├── freshness.ex               # ttl_for(endpoint, entity_state) → :immutable | {:ttl, seconds}; is_stale?/2
│   │   └── keys.ex                    # canonical cache key + params hash (sha256 of sorted params)
│   │
│   ├── mcp/                           # ── CONTEXT: MCP server, tools, prompts ──
│   │   ├── server.ex                  # Hermes MCP server module (registers tools + prompts, Streamable HTTP)
│   │   ├── client.ex                  # Hermes MCP client wrapper the Jido agent uses (tools/list, tools/call, prompts/get)
│   │   ├── tools/                     # one module per tool implementing the Hermes tool behaviour
│   │   │   ├── get_schedule.ex
│   │   │   ├── get_boxscore.ex
│   │   │   ├── get_homers_by_date.ex
│   │   │   ├── get_player_streaks.ex
│   │   │   ├── lookup_player.ex
│   │   │   ├── get_player_stats.ex
│   │   │   ├── get_probable_pitchers.ex
│   │   │   ├── get_matchups_for_players.ex
│   │   │   └── research_player_matchup.ex
│   │   └── prompts/
│   │       ├── hrs_yesterday_with_streaks.ex   # MCP prompt = default question #1
│   │       └── matchup_odds_followup.ex        # MCP prompt = default question #2
│   │
│   ├── agent/                         # ── CONTEXT: Jido agent orchestration ──
│   │   ├── fan_agent.ex               # Jido agent definition (name, skills/actions, MCP-client tool routing)
│   │   ├── conversation.ex            # GenServer per chat session: holds message history, runs the Anthropic loop
│   │   ├── loop.ex                    # Pure-ish orchestration: build request, dispatch tools, assemble tool_result turn
│   │   └── tool_router.ex            # Maps Anthropic tool_use{name,input} → MlbFan.Mcp.Client.call_tool/2
│   │
│   ├── llm/                           # ── CONTEXT: Anthropic client + cost tracking ──
│   │   ├── anthropic.ex               # Raw HTTP client (Req), streaming SSE, prompt caching, adaptive thinking
│   │   ├── sse.ex                     # SSE event parser: message_start/content_block_*/message_delta/message_stop
│   │   ├── pricing.ex                 # model → {input_per_mtok, output_per_mtok}; cache write/read multipliers
│   │   ├── cost_tracker.ex            # Insert llm_usage rows; compute USD; per-session + per-message aggregation
│   │   └── schemas/
│   │       └── llm_usage.ex           # Ecto schema
│   │
│   ├── research/                      # ── CONTEXT: Exa deep research ──
│   │   ├── exa.ex                     # Exa client (Req): search/2, contents/1 — mined from sports-fanatic
│   │   ├── matchup.ex                 # Per-player fan-out: build queries, Task.async_stream, dedup, package for Claude
│   │   └── api_usage.ex               # Insert api_usage rows (Exa) + cost
│   │
│   ├── mlb/                           # ── Ecto schemas for the mirror ──
│   │   ├── schemas/
│   │   │   ├── team.ex
│   │   │   ├── player.ex
│   │   │   ├── game.ex
│   │   │   ├── box_score.ex
│   │   │   ├── batting_line.ex        # per player per game hitting log
│   │   │   ├── pitching_line.ex       # per player per game pitching log
│   │   │   ├── home_run_event.ex      # one row per HR (batter, pitcher, game, inning)
│   │   │   └── raw_response.ex        # raw-response cache (endpoint+params_hash → body + fetched_at + ttl)
│   │   └── answers/
│   │       └── answer_cache.ex        # optional final-answer cache (question_key, date → rendered answer + cost)
│   │
│   └── cost/
│       └── projection.ex             # Daily/monthly cost projection from llm_usage + api_usage
│
└── mlb_fan_web/
    ├── endpoint.ex                    # Phoenix endpoint; mounts Hermes MCP at /mcp (wiring B)
    ├── router.ex                      # "/" → ChatLive; "/mcp" → Hermes plug; "/health"
    ├── telemetry.ex
    ├── components/
    │   ├── core_components.ex
    │   └── cost_readout.ex            # function component: per-message + per-session cost badges
    └── live/
        ├── chat_live.ex               # ChatLive: mount (welcome msg, autofocus), events, PubSub subscribe, streaming render
        └── chat_live.html.heex        # markup: message list, default question buttons, input, cost readout
```

---

## 4. Ecto Schemas (mirror + cache tables)

All timestamps `utc_datetime_usec`. All money stored as `:decimal` USD (never float). MLB entity IDs
are the canonical `statsapi` integer IDs, stored as `:bigint`, used as natural keys where noted.

### 4.1 `teams`
| field | type | notes |
|---|---|---|
| id | bigserial PK | internal |
| mlb_id | bigint | UNIQUE, statsapi team id |
| name | string | "New York Yankees" |
| abbreviation | string | "NYY" |
| team_code | string | nullable |
| league_name | string | nullable |
| division_name | string | nullable |
| venue_mlb_id | bigint | nullable |
| inserted_at / updated_at | | |

Indexes: `unique_index(:teams, [:mlb_id])`.

### 4.2 `players`
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| mlb_id | bigint | UNIQUE, statsapi person id |
| full_name | string | |
| first_name / last_name | string | nullable |
| primary_position | string | e.g. "RF","SP" |
| bat_side | string | "L"/"R"/"S" nullable |
| pitch_hand | string | "L"/"R" nullable |
| current_team_mlb_id | bigint | nullable |
| active | boolean | default true |
| inserted_at / updated_at | | |

Indexes: `unique_index(:players, [:mlb_id])`, `index(:players, [:full_name])` (case-insensitive lookup helper).

### 4.3 `games`
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| game_pk | bigint | UNIQUE, statsapi gamePk |
| game_date | date | official date (Eastern) |
| game_datetime | utc_datetime_usec | gameDate ISO |
| game_type | string | "R","P", etc |
| double_header | string | "N","Y","S" |
| game_number | integer | 1 or 2 |
| abstract_state | string | "Preview","Live","Final" |
| detailed_state | string | nullable |
| home_team_mlb_id | bigint | |
| away_team_mlb_id | bigint | |
| home_score | integer | nullable |
| away_score | integer | nullable |
| home_probable_pitcher_mlb_id | bigint | nullable |
| away_probable_pitcher_mlb_id | bigint | nullable |
| venue_mlb_id | bigint | nullable |
| venue_name | string | nullable |
| inserted_at / updated_at | | |

Indexes: `unique_index(:games, [:game_pk])`, `index(:games, [:game_date])`,
`index(:games, [:home_team_mlb_id])`, `index(:games, [:away_team_mlb_id])`.

### 4.4 `box_scores`
Stores the parsed, per-game "we have ingested this game's box" marker plus a pointer to lines.
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| game_pk | bigint | UNIQUE FK→games.game_pk |
| ingested_at | utc_datetime_usec | |
| final | boolean | true once game abstract_state="Final" (immutable thereafter) |
| inserted_at / updated_at | | |

Indexes: `unique_index(:box_scores, [:game_pk])`.

### 4.5 `batting_lines` (per player per game hitting log — drives streaks)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| game_pk | bigint | FK→games |
| game_date | date | denormalized for fast streak windows |
| player_mlb_id | bigint | FK→players |
| team_mlb_id | bigint | |
| batting_order | integer | nullable; nil = did not appear in order |
| plate_appearances | integer | default 0 |
| at_bats | integer | default 0 |
| hits | integer | default 0 |
| doubles / triples | integer | default 0 |
| home_runs | integer | default 0 |
| rbi | integer | default 0 |
| walks | integer | default 0 |
| strikeouts | integer | default 0 |
| appeared | boolean | true if player was in the game at all (incl. pinch/PR) |
| inserted_at / updated_at | | |

Indexes: `unique_index(:batting_lines, [:game_pk, :player_mlb_id])`,
`index(:batting_lines, [:player_mlb_id, :game_date])` (streak window scan).

### 4.6 `pitching_lines` (per player per game pitching log)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| game_pk / game_date / player_mlb_id / team_mlb_id | | as above |
| innings_pitched | decimal | e.g. 6.1 stored as 6.33 or as string→normalized; store `outs` too |
| outs | integer | authoritative innings measure (IP*3) |
| hits_allowed / runs / earned_runs | integer | |
| home_runs_allowed | integer | |
| walks / strikeouts | integer | |
| batters_faced | integer | |
| is_starter | boolean | |
| inserted_at / updated_at | | |

Indexes: `unique_index(:pitching_lines, [:game_pk, :player_mlb_id])`,
`index(:pitching_lines, [:player_mlb_id, :game_date])`.

### 4.7 `home_run_events` (one row per HR, with pitcher context — powers `get_homers_by_date`)
Populated from play-by-play (`/api/v1/game/{gamePk}/playByPlay`, or v1.1 feed/live).
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| game_pk | bigint | FK→games |
| game_date | date | |
| batter_mlb_id | bigint | FK→players |
| pitcher_mlb_id | bigint | FK→players |
| batter_team_mlb_id | bigint | |
| pitcher_team_mlb_id | bigint | |
| inning | integer | |
| half_inning | string | "top"/"bottom" |
| rbi | integer | HR RBI count (solo=1..grand slam=4) |
| description | text | play description string |
| at_bat_index | integer | ordering within game |
| inserted_at / updated_at | | |

Indexes: `unique_index(:home_run_events, [:game_pk, :at_bat_index])`,
`index(:home_run_events, [:game_date])`, `index(:home_run_events, [:batter_mlb_id, :game_date])`.

### 4.8 `raw_responses` (endpoint+params raw-response cache with TTL)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| endpoint | string | registry name, e.g. "schedule" |
| params_hash | string | sha256 hex of canonical sorted params |
| params_json | jsonb | for debugging/inspection |
| body | jsonb | full decoded response |
| status_code | integer | |
| fetched_at | utc_datetime_usec | |
| ttl_seconds | integer | nil = immutable (cache forever) |
| immutable | boolean | true for completed games |
| inserted_at / updated_at | | |

Indexes: `unique_index(:raw_responses, [:endpoint, :params_hash])`,
`index(:raw_responses, [:fetched_at])`.

Freshness: on read, HIT iff `immutable == true` OR `fetched_at + ttl_seconds > now`. Otherwise MISS
(re-fetch and upsert).

### 4.9 `llm_usage` (per Anthropic request cost — see §10)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| session_id | string | chat session (LiveView) id |
| message_id | string | assistant message id (Anthropic `message.id`) |
| question_label | string | "hrs_yesterday" \| "matchup_odds" \| "freeform" |
| model | string | "claude-opus-4-8" |
| input_tokens | integer | |
| output_tokens | integer | |
| cache_creation_input_tokens | integer | default 0 |
| cache_read_input_tokens | integer | default 0 |
| cost_usd | decimal | computed at insert (see pricing formula) |
| stop_reason | string | end_turn/tool_use/max_tokens/refusal/pause_turn |
| turn_index | integer | which loop iteration (0..n) |
| inserted_at | | |

Indexes: `index(:llm_usage, [:session_id])`, `index(:llm_usage, [:inserted_at])`,
`index(:llm_usage, [:question_label])`.

### 4.10 `api_usage` (per external non-LLM API call cost — Exa)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| session_id | string | nullable |
| provider | string | "exa" |
| operation | string | "search" \| "contents" |
| units | integer | # searches or # contents docs |
| cost_usd | decimal | units × configured unit price |
| meta | jsonb | query, numResults, etc (no secrets) |
| inserted_at | | |

Indexes: `index(:api_usage, [:provider, :inserted_at])`, `index(:api_usage, [:session_id])`.

### 4.11 `answer_cache` (optional — free daily default question after first ask)
| field | type | notes |
|---|---|---|
| id | bigserial PK | |
| question_key | string | "hrs_yesterday" \| "matchup_odds" |
| for_date | date | the "yesterday"/"today" the answer is about |
| rendered_markdown | text | final assistant answer |
| cost_usd | decimal | cost of the run that produced it (for reporting) |
| built_at | utc_datetime_usec | |
| inserted_at / updated_at | | |

Indexes: `unique_index(:answer_cache, [:question_key, :for_date])`.

---

## 5. MCP Tool Catalog

Each tool below lists name, description (as sent to Claude — concise and behavioral), input_schema
(JSON Schema draft the coding agent registers verbatim), and the backing `MlbFan.Stats`/`Research`
call. All tools return **JSON** (a map) as their result content; the agent JSON-decodes tool inputs
and passes results back as `tool_result` blocks. Dates are `YYYY-MM-DD` (ISO 8601) in tool I/O; the
MLB API's `MM/DD/YYYY` format is an internal detail of the port.

### 5.1 `get_schedule`
- **description**: "Get the MLB game schedule for a date, including teams, status, venue, and probable
  starting pitchers. Use to find which games are played on a given day."
- **input_schema**:
```json
{"type":"object","properties":{
  "date":{"type":"string","description":"ISO date YYYY-MM-DD. Defaults to today (America/New_York)."}
},"required":[]}
```
- **backs**: `MlbFan.Stats.schedule(date, hydrate: [:probablePitcher, :linescore, :venue, :team])`.

### 5.2 `get_boxscore`
- **description**: "Get the full box score for a single game by its gamePk: per-player batting and
  pitching lines for both teams."
- **input_schema**:
```json
{"type":"object","properties":{
  "game_pk":{"type":"integer","description":"MLB gamePk from the schedule."}
},"required":["game_pk"]}
```
- **backs**: `MlbFan.Stats.boxscore(game_pk)`.

### 5.3 `get_homers_by_date`  (default question #1 primary tool)
- **description**: "List every home run hit on a given date across MLB, with the batter, the pitcher
  who allowed it, the teams, inning, and RBIs. Use for 'who hit a home run yesterday'."
- **input_schema**:
```json
{"type":"object","properties":{
  "date":{"type":"string","description":"ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York)."}
},"required":[]}
```
- **backs**: `MlbFan.Stats.homers_by_date(date)` → reads `home_run_events` (fills via schedule→playByPlay on miss).
- **returns**: `{"date":..., "count":N, "home_runs":[{"batter":{"mlb_id","name","team"},"pitcher":{"mlb_id","name","team"},"inning","half","rbi","game_pk","description"}...]}`.

### 5.4 `get_player_streaks`  (default question #1 companion)
- **description**: "For one or more players, compute their current home-run streak and hitting streak
  over the last N team games. HR streak = consecutive team games with at least one HR by the player.
  Hitting streak = consecutive games with at least one hit. Days off do not break a streak."
- **input_schema**:
```json
{"type":"object","properties":{
  "player_mlb_ids":{"type":"array","items":{"type":"integer"},"description":"MLB person ids."},
  "window_days":{"type":"integer","default":30,"description":"How many days of game logs to scan back."},
  "as_of_date":{"type":"string","description":"ISO date; streak computed as of end of this day. Defaults to today."}
},"required":["player_mlb_ids"]}
```
- **backs**: `MlbFan.Stats.player_streaks(ids, window_days: n, as_of: date)` → ensures last-N-days box
  scores are mirrored, then `MlbFan.Stats.Streaks.compute/2` from `batting_lines`.
- **returns**: `{"as_of":..., "players":[{"mlb_id","name","hr_streak","hitting_streak","last_hr_date","games_scanned"}...]}`.

### 5.5 `lookup_player`
- **description**: "Resolve a player name to their MLB person id and basic bio (position, bats/throws,
  team). Use before other tools when you only have a name."
- **input_schema**:
```json
{"type":"object","properties":{
  "name":{"type":"string","description":"Full or partial player name."}
},"required":["name"]}
```
- **backs**: `MlbFan.Stats.lookup_player(name)` (statsapi `/people/search`).

### 5.6 `get_player_stats`
- **description**: "Get a player's season hitting or pitching stats for a given season and group."
- **input_schema**:
```json
{"type":"object","properties":{
  "player_mlb_id":{"type":"integer"},
  "group":{"type":"string","enum":["hitting","pitching"],"default":"hitting"},
  "season":{"type":"integer","description":"4-digit year. Defaults to current season."}
},"required":["player_mlb_id"]}
```
- **backs**: `MlbFan.Stats.player_stats(id, group: g, season: y)` (statsapi `/people/:id/stats?stats=season&group=...`).

### 5.7 `get_probable_pitchers`
- **description**: "For a date, list each game's probable starting pitchers (home and away) with ids
  and hands. Use to find who a hitter's team faces today."
- **input_schema**:
```json
{"type":"object","properties":{
  "date":{"type":"string","description":"ISO date YYYY-MM-DD. Defaults to today."}
},"required":[]}
```
- **backs**: `MlbFan.Stats.probable_pitchers(date)` (schedule hydrated with probablePitcher).

### 5.8 `get_matchups_for_players`  (default question #2 primary tool)
- **description**: "Given a list of hitters, find today's game for each hitter's team and the opposing
  probable starting pitcher. Returns hitter→opponent-pitcher pairs with basic stats for both."
- **input_schema**:
```json
{"type":"object","properties":{
  "player_mlb_ids":{"type":"array","items":{"type":"integer"}},
  "date":{"type":"string","description":"ISO date YYYY-MM-DD. Defaults to today."}
},"required":["player_mlb_ids"]}
```
- **backs**: `MlbFan.Stats.matchups_for_players(ids, date)` → resolves each player's current team,
  finds today's schedule game for that team, extracts opposing probable pitcher, joins season stats
  for hitter (HR, AVG, SLG, bat side) and pitcher (HR/9, ERA, WHIP, pitch hand).
- **returns**: `{"date":..., "matchups":[{"hitter":{...,"bat_side","season":{...}},"opponent_pitcher":{...,"pitch_hand","season":{...}},"venue","game_pk"} | {"hitter":{...},"no_game":true}...]}`.

### 5.9 `research_player_matchup`  (default question #2 fan-out; Exa-backed)
- **description**: "Deep web research for a single hitter-vs-pitcher matchup: recent form, the
  pitcher's HR vulnerability vs the hitter's handedness, ballpark HR factor, and weather/forecast.
  Returns compact research snippets with source URLs for the model to synthesize into a likelihood
  assessment. Call once per hitter; calls run in parallel."
- **input_schema**:
```json
{"type":"object","properties":{
  "hitter_name":{"type":"string"},
  "hitter_mlb_id":{"type":"integer"},
  "pitcher_name":{"type":"string"},
  "pitcher_mlb_id":{"type":"integer"},
  "venue":{"type":"string"},
  "date":{"type":"string","description":"ISO date YYYY-MM-DD."}
},"required":["hitter_name","pitcher_name"]}
```
- **backs**: `MlbFan.Research.Matchup.research(args)` → builds 4 query angles (see §9), fans them out via
  `Task.async_stream` to `MlbFan.Research.Exa.search/2`, dedups by domain, records `api_usage`, returns
  `{"hitter","pitcher","snippets":[{"angle","title","url","text","published_date"}...]}`.

**NOTE on fan-out placement**: `research_player_matchup` is ONE tool called ONCE PER HITTER by Claude.
The agent (§ tool router) executes all `tool_use` blocks from a single turn concurrently, so when Claude
emits N `research_player_matchup` calls in one turn they run in parallel automatically (bounded
`Task.async_stream` at the router level). Additionally, each single call fans out its 4 Exa angles in
parallel internally. This gives the "many parallel Exa calls" behavior the user wants.

### 5.10 MCP Prompts (parameterized)
Hermes exposes prompts via `prompts/list` + `prompts/get`. Two prompts, mirroring the default buttons.

**`hrs_yesterday_with_streaks`**
- **arguments**: `date` (optional, ISO; default yesterday ET).
- **get → messages**: a single user message:
  > "For {date}, list everyone who hit a home run and, for each of those players, their current
  > home-run streak (consecutive team games with at least one HR) and hitting streak. Use
  > get_homers_by_date then get_player_streaks. Present a clean table sorted by HR streak descending,
  > then a short note on any multi-HR games that day."

**`matchup_odds_followup`**
- **arguments**: `player_mlb_ids` (array, required — the HR hitters from the prior answer), `date`
  (optional, default today ET).
- **get → messages**: a single user message:
  > "From the list of players who homered yesterday ({player_mlb_ids}), determine who is playing today
  > and against which probable starting pitcher, then assess each hitter's chance of doing well today
  > (especially multi-HR / back-to-back-HR potential) based on the pitcher's and hitter's stats plus
  > deep research. Use get_matchups_for_players, then call research_player_matchup once per hitter.
  > For each hitter give a 1–10 confidence score, the key supporting factors, and cite sources.
  > Rank the list best-to-worst. Include the responsible-gambling note."

---

## 6. Anthropic System Prompt (draft) + API constraints

### 6.1 System prompt (FROZEN — no timestamps; "today" injected via user turn)
Place the entire system content in ONE system block (or two blocks where the last carries
`cache_control`). The tool definitions array + this system block must be byte-stable across requests so
prompt caching hits. Inject the current date only in user messages, never here.

```
You are MLB Fan Agent, a sharp, honest MLB statistics analyst specializing in home-run streak
research for daily betting angles. You help a user study which hitters homered recently, their HR and
hitting streaks, and how likely they are to hit a home run (including multi-HR games) in today's
matchup.

TOOLS & METHOD
- You have no built-in knowledge of today's games or current stats. ALWAYS get facts from tools; never
  invent stat lines, streaks, matchups, or dates.
- To answer "who homered on date D": call get_homers_by_date, then get_player_streaks for those
  players. Sort and present clearly.
- To assess today's chances: call get_matchups_for_players to pair each hitter with today's opposing
  probable pitcher, then call research_player_matchup ONCE PER HITTER (these run in parallel) to gather
  recent form, the pitcher's HR/9 vs the hitter's handedness, ballpark HR factor, and weather. Then
  synthesize.
- Tool inputs are JSON. Read the actual returned data; do not guess field values.
- If a tool returns no game for a player today, say so plainly (off day / not scheduled).

ANALYSIS STYLE
- For each hitter you assess today, give a 1-10 CONFIDENCE SCORE for a strong offensive game / HR
  potential, followed by 2-4 bullet reasons grounded in the retrieved stats and research, and cite
  source URLs from research snippets.
- Weight signals sensibly: a hot HR streak, favorable handedness split (LHB vs RHP or a pitcher with
  high HR/9 to that side), a hitter-friendly park, and wind blowing out all raise the score; a strong
  swing-and-miss pitcher, pitcher-friendly park, cold streak, or recent day-to-day injury lower it.
- Be explicit about small sample sizes and uncertainty. A 1-2 game HR streak is a weak signal by
  itself; say so. Never overstate confidence.

FORMAT
- Use concise markdown. Prefer a table for lists (player | HR streak | hitting streak | today's
  pitcher | park | score). Keep prose tight. Put the confidence score first for each matchup.

RESPONSIBLE USE
- End any betting-relevant answer with: "For research and entertainment only. No outcome is
  guaranteed; past streaks do not predict future results. Bet responsibly and within your means. If
  gambling is a problem, call 1-800-GAMBLER."
```

The final system block carries `"cache_control": {"type": "ephemeral"}` so tools + system cache together.

### 6.2 Request shape (authoritative — do not contradict)
```json
{
  "model": "claude-opus-4-8",
  "max_tokens": 4096,
  "stream": true,
  "thinking": {"type": "adaptive"},
  "system": [{"type":"text","text":"<frozen system prompt>","cache_control":{"type":"ephemeral"}}],
  "tools": [ <tool defs, stable order> ],
  "messages": [ ... ]
}
```
Hard rules (each is a 400 on opus-4-8 if violated):
- **NEVER** send `temperature`, `top_p`, or `top_k`.
- **NEVER** send `budget_tokens`; thinking is `{"type":"adaptive"}` only.
- **Always** `"stream": true`.

Headers (required):
```
x-api-key: $ANTHROPIC_API_KEY
anthropic-version: 2023-06-01
content-type: application/json
```
Resolve the key exactly like sports-fanatic: `Application.get_env(:mlb_fan, :anthropic_api_key) ||
System.get_env("ANTHROPIC_API_KEY")`. Never log the key or full headers.

### 6.3 SSE parsing (`MlbFan.Llm.Sse`)
Consume the response as a stream (Req `into: :self` / streaming callback). Parse `event:`/`data:` lines
into these event types and handle:
- `message_start` → capture `message.id`, initial `usage` (input, cache_read, cache_creation).
- `content_block_start` → note block type (`text`, `thinking`, `tool_use`); for `tool_use` capture
  `id`, `name`; begin buffering `input` JSON.
- `content_block_delta` →
  - `text_delta` → push token to LiveView via PubSub (stream to user).
  - `thinking_delta` → optional: may be shown collapsed or dropped; do NOT stream as answer text.
  - `input_json_delta` → append `partial_json` to the current tool_use's input buffer.
- `content_block_stop` → finalize the block; JSON-decode the tool_use input buffer.
- `message_delta` → carries `stop_reason` and cumulative `usage.output_tokens`. Persist usage.
- `message_stop` → turn complete.

Handle `stop_reason`:
- `end_turn` → done; render final answer; record cost.
- `tool_use` → execute ALL buffered `tool_use` blocks (see § toolloop), append ONE user message with
  ALL `tool_result` blocks, loop.
- `max_tokens` → answer truncated; surface a "response truncated" note; optionally continue.
- `refusal` → surface a safe refusal message.
- `pause_turn` → re-issue the request with the accumulated assistant content to resume (long tool/think
  turns); loop without user input.

### 6.4 Tool-use loop (`MlbFan.Agent.Loop`)
1. Send request. Stream. Collect assistant content blocks (text + tool_use).
2. On `stop_reason == tool_use`: for EACH `tool_use` block, route `{name, input}` →
   `MlbFan.Mcp.Client.call_tool(name, input)`. Run the blocks concurrently
   (`Task.async_stream`, `max_concurrency: 8`, per-tool timeout 30s; research tool 60s).
3. Assemble a SINGLE `user` message containing ALL `tool_result` blocks (order irrelevant but include
   `tool_use_id` for each). Errors become `{"type":"tool_result","tool_use_id":..,"is_error":true,
   "content":"<message>"}`.
4. Append the assistant turn + the tool_result user turn to `messages`; go to 1.
5. Cap loop at N=8 iterations (guard against runaway); if exceeded, stop with a diagnostic.
6. After each request, insert an `llm_usage` row (turn_index, tokens, cost, stop_reason).

### 6.5 Prompt caching accounting
Track per response: `usage.cache_creation_input_tokens` (first call writes system+tools to cache) and
`usage.cache_read_input_tokens` (subsequent calls read them). Feed both into the cost formula (§10).

---

## 7. The Two Default Questions (button labels + prompt text)

Rendered under the welcome message. Button #2 is **hidden until question #1 has been answered** (track
`assigns.answered_q1`), because it operates on "this list" from answer #1.

**Button #1**
- Label (exact): `⚾ Who homered yesterday — and their HR streaks`
- Question text sent as the user turn (also injects today's date so the model knows "yesterday"):
  > "Today is {today ISO, America/New_York}. Show everyone who hit a home run yesterday and, for each,
  > their current HR streak and hitting streak. Sort by HR streak (highest first) and flag any multi-HR
  > games."
- `question_label = "hrs_yesterday"`.

**Button #2** (appears after #1 answered)
- Label (exact): `🎯 Who's pitching against them today — and their chances`
- Question text sent as the user turn (the LiveView passes the HR-hitter ids gathered from answer #1;
  if none tracked structurally, the text references "the players from the previous answer" and the
  model re-derives via tools):
  > "Today is {today ISO}. From the players who homered yesterday, who is playing today and against
  > which probable starting pitcher? Assess each hitter's chance of a strong game / home run today
  > (including multi-HR potential) using the pitcher's and hitter's stats plus deep research. Give each
  > a 1–10 confidence score, cite sources, and rank best-to-worst."
- `question_label = "matchup_odds"`.

The LiveView may equivalently drive these through the MCP prompts (`prompts/get`) rather than inline
text — either is acceptable; inline text is simpler and is the default. When the MCP prompt path is
used, the returned prompt messages are appended as the user turn.

---

## 8. Streak Algorithms (`MlbFan.Stats.Streaks`)

Streaks are computed over a player's **team games in chronological order** within the scan window, read
from `batting_lines` joined to `games` (ordered by `game_date`, then `game_number` for doubleheaders).

### 8.1 Definitions
- **HR streak** = the number of consecutive most-recent team games (that the player appeared in) in
  which the player hit ≥1 home run. Counting starts from the most recent completed game and walks
  backward; it stops at the first appeared-game with 0 HR.
- **Hitting streak** = same, but ≥1 hit.

### 8.2 Precise rules & edge cases
1. **Order**: sort the player's game logs ascending by `(game_date, game_number)`; walk from the newest
   backward.
2. **Only completed games count** (`games.abstract_state == "Final"`). Today's in-progress or preview
   game does not participate until Final.
3. **Days off do NOT break a streak.** Streaks are over *games the player appeared in*, not calendar
   days. Gaps in dates are irrelevant.
4. **Games the player did NOT appear in are skipped, not streak-breakers.** If the team played but the
   player was benched/rested (`appeared == false`, i.e. not in `batting_lines` or `appeared=false`),
   that game is ignored for streak continuity. (Rationale: standard MLB streak convention counts games
   played by the player. Note this choice in code docs; it matches how "hitting streak" is officially
   tracked — a game where the player has 0 official AB and no hit but only a walk does NOT break a
   hitting streak; see rule 6.)
5. **Doubleheaders**: both games are separate rows (`game_number` 1 and 2); each counts independently
   and in order.
6. **Hitting-streak walk/HBP exception (official rule)**: a game in which the player had **zero at-bats**
   because of walks/HBP/sacrifice only (0 AB, 0 H) does **not** break a hitting streak — that game is
   skipped for hitting-streak purposes. A game with ≥1 AB and 0 H **breaks** it. Implement:
   for hitting streak, treat a game as "skip" when `at_bats == 0 and hits == 0` (all PA were BB/HBP/SF);
   "extend" when `hits >= 1`; "break" when `at_bats >= 1 and hits == 0`.
7. **HR-streak sacrifice/walk games**: a game with 0 AB and 0 HR (only walks) — apply the same skip
   convention as hitting for consistency (a pure-walk game neither extends nor breaks the HR streak).
   A game with ≥1 AB and 0 HR breaks the HR streak.
8. **Pinch-hit / pinch-run appearances**: a pinch-hit AB with a HR extends the HR streak; a pinch-run
   with 0 PA is a skip (no offensive opportunity). Drive this off `plate_appearances`/`at_bats`, not
   position.
9. **Window bound**: only scan `window_days` back (default 30). If the streak would extend past the
   window boundary, report the streak length within the window and set a `window_truncated: true` flag
   so Claude can caveat. (30 days comfortably covers any realistic active HR streak.)
10. **Empty data**: no game logs in window → streak 0, `games_scanned: 0`.

### 8.3 Data-availability guarantee
Before computing, `player_streaks/2` ensures the mirror has box scores for the relevant window:
determine the player's team, list that team's games in the window from `games` (fetching the schedule
per-day through the cache if absent), and for each Final game lacking a `batting_lines` row for the
player, fetch+persist that game's box score (DB-first). Then compute purely from the DB. This is how
"who has a 7-day hitting streak" works: fetch the last 7 days of box scores (DB-or-API-then-DB) and
compute from the DB.

---

## 9. Matchup Research Flow (default question #2)

```
Claude turn 1: get_matchups_for_players([hitter ids], today)
   └─ Stats: for each hitter → current team → today's schedule game → opposing probable pitcher
             → join hitter season stats (HR, AVG, SLG, ISO, bat_side)
             → join pitcher season stats (HR/9, ERA, WHIP, K/9, pitch_hand, home/away)
   └─ returns hitter↔pitcher pairs (+ venue, park) ; hitters with no game flagged no_game=true

Claude turn 2: research_player_matchup(...) ONCE PER HITTER  (Claude emits N calls in one turn)
   For each call, MlbFan.Research.Matchup fans out 4 Exa query angles in parallel:
     A) recent form:    "{hitter} recent home runs form last 2 weeks 2026"
     B) pitcher HR risk:"{pitcher} home runs allowed vs {LHB|RHB} HR/9 2026"  (side = hitter bat_side)
     C) park factor:    "{venue} home run park factor 2026"
     D) weather:        "{venue} weather forecast wind {date} game"
   → Task.async_stream(max_concurrency: 4) → Exa.search(angle, num_results: 4, days_back: 21)
   → dedup_by_domain, take top snippets per angle, record api_usage(exa, search, units=#queries)
   → return {hitter, pitcher, snippets:[{angle,title,url,text,published_date}...]}

Claude turn 3 (synthesis): for each hitter produce
   - CONFIDENCE 1-10 (strong offensive game / HR potential today)
   - 2-4 grounded bullets (streak, handedness split, park, weather, pitcher HR/9, injuries)
   - cited source URLs
   - ranked best→worst table + responsible-gambling note
```

Scoring guidance is in the system prompt (§6.1), not hardcoded — Claude assigns the 1–10 from the
retrieved stats + research. The app does not compute the odds numerically in v1 (documented future
enhancement: a deterministic feature-based prior to anchor Claude's score).

Concurrency budget: N hitters × 4 angles. The tool router caps concurrent `research_player_matchup`
tool executions at 8, and each internally caps Exa at 4, so worst-case ~32 in-flight Exa requests.
Exa client has retry/backoff (mined). Bound total via `Task.async_stream` timeouts (60s per tool).

---

## 10. Cost Model (concrete)

### 10.1 Pricing map (`MlbFan.Llm.Pricing`) — USD per 1M tokens
| model | input | output |
|---|---|---|
| **claude-opus-4-8 (default)** | $5.00 | $25.00 |
| claude-sonnet-4-6 | $3.00 | $15.00 |
| claude-haiku-4-5 | $1.00 | $5.00 |

Cache multipliers (Anthropic standard): **cache write = 1.25×** input rate, **cache read = 0.10×**
input rate. For opus-4-8: cache write = $6.25/M, cache read = $0.50/M.

### 10.2 Per-request cost formula (computed at `llm_usage` insert)
```
cost_usd =
    input_tokens                  / 1_000_000 * input_rate
  + output_tokens                 / 1_000_000 * output_rate
  + cache_creation_input_tokens   / 1_000_000 * input_rate * 1.25
  + cache_read_input_tokens       / 1_000_000 * input_rate * 0.10
```
For opus-4-8: `in×$5 + out×$25 + cache_write×$6.25 + cache_read×$0.50` per million. Store as `:decimal`
rounded to 6 dp.

### 10.3 Exa cost (`MlbFan.Research.ApiUsage`)
Configurable unit prices (defaults, override via config/env):
- search: **$0.005 / search** (i.e. $5 / 1k searches).
- contents: **$0.001 / document** retrieved (only if `/contents` is called; v1 uses inline
  `contents.text` on search, so contents cost is usually $0 — record `units=0` unless `/contents` used).
`cost_usd = units × unit_price`.

### 10.4 Worked projection for the two daily default questions
Assumptions (label clearly as estimates; refine from real `llm_usage` after first runs):

**Question #1 (hrs_yesterday)** — a typical MLB day: ~15 games, ~20–35 HRs, ~25 hitters.
- System prompt + tool defs ≈ 2.0K tokens → cached after first call of the day
  (first call: cache-write 2.0K; later calls same day: cache-read 2.0K).
- Tool results are the input driver: `get_homers_by_date` (~25 HR rows ≈ 3K tokens) +
  `get_player_streaks` for ~25 players (~4K tokens). Box-score-derived data is compact JSON.
- Loop: turn0 (ask+tools) → turn1 (2 tool calls) → turn2 (final answer).
- Rough input over the run: ~2K (system, cache-write once) + ~7K (tool results, uncached) + ~1K
  (messages) ≈ 10K input tokens. Output: table + notes ≈ 1.2K tokens.
- Cost ≈ `10K×$5/M + 1.2K×$25/M + (2K cache-write once)×$6.25/M`
  ≈ $0.050 + $0.030 + $0.0125 ≈ **~$0.093 first run of the day**; **~$0.083** on same-day reruns
  (system read-cached instead of written).

**Question #2 (matchup_odds)** — the expensive one.
- `get_matchups_for_players` (~15–25 hitters with 2 stat blocks each ≈ 6K tokens).
- N `research_player_matchup` results: say 18 hitters have games; each returns ~6 snippets × ~400 tok
  ≈ 2.4K tokens → 18 × 2.4K ≈ 43K tokens of tool_result input. This dominates.
- System/tools cache-read (2K). Loop ~3–4 turns.
- Input ≈ 2K (cache-read) + 6K + 43K + a few K messages ≈ ~53K input tokens. Output: per-hitter
  writeups + ranked table ≈ 3K tokens.
- Anthropic cost ≈ `53K×$5/M + 3K×$25/M + 2K cache-read×$0.50/M`
  ≈ $0.265 + $0.075 + $0.001 ≈ **~$0.34**.
- Exa cost: 18 hitters × 4 searches = 72 searches × $0.005 ≈ **$0.36**.
- **Question #2 total ≈ ~$0.70 per run.**

**Both default questions, once/day** ≈ $0.09 + $0.70 ≈ **~$0.79/day** → **~$24/month**. With
answer-caching (below), reruns of the SAME day's default question are **$0** (served from
`answer_cache`), so a single-user daily habit stays near the once-per-day figure.

Cheaper-model projection (for the dashboard "what-if"): the same token profile on **sonnet-4-6**
(input $3 / output $15) ≈ Q1 ~$0.05, Q2 Anthropic ~$0.20 (+$0.36 Exa) → both ≈ ~$0.61/day (~$18/mo);
on **haiku-4-5** ($1/$5) ≈ Q1 ~$0.016, Q2 Anthropic ~$0.068 (+$0.36 Exa) → ~$0.44/day (~$13/mo). Exa
is the floor for Q2 regardless of model. Default remains opus-4-8 (do not downgrade).

### 10.5 Cache economics (spec the tradeoff)
- The Postgres **stats** cache does NOT reduce Anthropic cost on a repeated question — Claude is
  re-asked with the same tool data, so token counts (and $) are unchanged. What it reduces is **MLB API
  load and tool latency** (DB hit vs network round-trips) and Exa is separately reduced only if the
  matchup research is cached.
- To make a repeated **daily default question free**, cache the FINAL ANSWER keyed by
  `(question_key, for_date)` in `answer_cache`. On button click, if a fresh answer exists for that date,
  render it instantly at $0 and skip the LLM entirely. Invalidate when `for_date` rolls over (new day)
  or on an explicit "refresh" affordance. Q2's answer cache should also key on the hitter-id set so a
  changed input list re-runs.

### 10.6 UI cost readout
- **Per-message badge**: sum of `llm_usage.cost_usd` (+ any `api_usage.cost_usd`) for that assistant
  message id → e.g. `$0.34 • 53.0K in / 3.0K out • opus-4-8`.
- **Per-session total**: running sum for `session_id`, shown in the header → `Session: $0.79`.
- **Projection widget**: "If you run both default questions daily: ~$24/mo on opus-4-8 (sonnet ~$18,
  haiku ~$13)." Computed from actual observed averages once ≥1 run of each exists, else the estimates
  above.

---

## 11. Config & Secrets, Docker Compose

### 11.1 `config/runtime.exs` (read env at boot; mirror sports-fanatic patterns)
```elixir
config :mlb_fan, MlbFan.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

config :mlb_fan, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
config :mlb_fan, :anthropic_model, System.get_env("ANTHROPIC_MODEL", "claude-opus-4-8")
config :mlb_fan, :exa, api_key: System.get_env("EXA_API_KEY")
config :mlb_fan, :exa_search_price_usd, System.get_env("EXA_SEARCH_PRICE_USD", "0.005")
config :mlb_fan, :exa_contents_price_usd, System.get_env("EXA_CONTENTS_PRICE_USD", "0.001")

config :mlb_fan, MlbFanWeb.Endpoint,
  url: [host: System.get_env("PHX_HOST", "localhost")],
  http: [ip: {0,0,0,0,0,0,0,0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: System.get_env("PHX_SERVER", "true") == "true"
```
Model is configurable but defaults to `claude-opus-4-8`. Pricing map lives in `MlbFan.Llm.Pricing`
(compile-time constant, no env needed) but Exa unit prices are env-overridable.

### 11.2 `.env.example` (ship this; user populates real values)
```
# Phoenix
SECRET_KEY_BASE=generate_with_mix_phx_gen_secret
PHX_HOST=localhost
PORT=4000

# Database
DATABASE_URL=ecto://postgres:postgres@localhost:5432/mlb_fan

# Anthropic
ANTHROPIC_API_KEY=your_anthropic_key
ANTHROPIC_MODEL=claude-opus-4-8

# Exa.ai
EXA_API_KEY=your_exa_key
EXA_SEARCH_PRICE_USD=0.005
EXA_CONTENTS_PRICE_USD=0.001
```

### 11.3 `docker-compose.yml`
```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=mlb_fan
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports: ["5432:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  web:
    build: .
    ports: ["4000:4000"]
    environment:
      - DATABASE_URL=ecto://postgres:postgres@db:5432/mlb_fan
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=${PHX_HOST:-localhost}
      - PORT=4000
      - PHX_SERVER=true
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-claude-opus-4-8}
      - EXA_API_KEY=${EXA_API_KEY}
      - EXA_SEARCH_PRICE_USD=${EXA_SEARCH_PRICE_USD:-0.005}
      - EXA_CONTENTS_PRICE_USD=${EXA_CONTENTS_PRICE_USD:-0.001}
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  pgdata:
```

### 11.4 `Dockerfile` (multi-stage mix release — model on sports-fanatic's)
- Build stage: `elixir:1.17-otp-27-slim`, `MIX_ENV=prod`, `deps.get --only prod`, `deps.compile`,
  copy config/lib/priv/assets, `mix assets.deploy`, `mix compile`, `mix phx.gen.release`, `mix release`.
- Runtime stage: `debian:bookworm-slim`, install `libstdc++6 openssl libncurses5 ca-certificates curl`,
  non-root `appuser`, copy release, `EXPOSE 4000`, `HEALTHCHECK curl -f http://localhost:4000/health`,
  entrypoint runs `bin/mlb_fan eval "MlbFan.Release.migrate()"` then `bin/mlb_fan start`.
- Add `MlbFan.Release` module for migrations in a release (standard Phoenix pattern).

---

## 12. Testing Strategy (ExUnit; NO live API calls in tests)

- **HTTP stubbing**: use `Req.Test` (Req's built-in test adapter) for all outbound HTTP (MLB Stats,
  Anthropic, Exa). Configure each client to accept an injectable Req plug/base so tests stub responses.
  Bypass is an acceptable alternative if a real socket is needed, but prefer `Req.Test` (no network).
- **Fixtures**: capture real JSON samples ONCE (dev, out of band) into `test/support/fixtures/` for:
  schedule (with probablePitcher), boxscore, playByPlay (HR plays), people/search, people/:id/stats,
  an Anthropic SSE stream (message_start … tool_use … message_stop, two-turn), and an Exa search
  response. Tests replay these; no key needed.
- **Streak unit tests** (`MlbFan.Stats.Streaks`): table-driven over synthetic `batting_lines`, covering
  every edge case in §8.2 — days off, benched games, doubleheaders, walk-only games (skip vs break),
  pinch-hit HR, window truncation, empty data.
- **Cache tests**: HIT vs MISS vs STALE for `raw_responses`; immutable Final games never re-fetched;
  short-TTL schedule re-fetches after expiry; params-hash stability regardless of param order.
- **Cost tests** (`MlbFan.Llm.Pricing`/`CostTracker`): exact `:decimal` cost for known token tuples on
  all three models incl. cache write/read; `api_usage` Exa cost.
- **SSE parser tests**: feed the fixture byte stream (including split-across-chunk boundaries) and
  assert emitted events, decoded tool inputs, final usage, and stop_reason handling.
- **Tool-loop tests**: given a stubbed Anthropic stream that returns `tool_use`, assert the router
  dispatches the right MCP tool, tool_result assembly is a single user message, and the loop terminates.
- **MCP tool tests**: call each tool module directly with stubbed Stats/Research; assert input_schema
  validation and JSON result shape. Also a round-trip through the Hermes client→server if feasible.
- **LiveView tests**: `Phoenix.LiveViewTest` — mount shows `Welcome to MLB Fan Agent`, input has
  `autofocus`, button #1 present and button #2 hidden until `answered_q1`, clicking pushes the expected
  event, streamed deltas append to the message, cost badge renders.
- **`test.unit` alias**: mirror sports-fanatic — a curated list of DB-free unit tests (streaks, pricing,
  sse, parsers, cache-keys) runnable without Postgres for fast feedback.
- CI gate: `mix test` must pass with zero network egress (assert via a Req.Test default that fails on
  un-stubbed requests).

---

## 13. Security Considerations (ISC2 mindset)

- **Secrets hygiene**: API keys only from env/`Application.get_env`; NEVER logged. Do not log full Req
  headers or request bodies for Anthropic/Exa. Redact `x-api-key`. `.env` is git-ignored; only
  `.env.example` is committed. (sports-fanatic Claude client already resolves keys this way — replicate.)
- **SQL injection**: N/A via Ecto parameterized queries; no string-built SQL. All external ids are cast
  to integers before query use.
- **Prompt injection via tool results / Exa content**: Exa returns third-party web text that flows into
  Claude. Treat it as untrusted data, never as instructions: (a) wrap research snippets clearly as DATA
  in tool_result, (b) the system prompt instructs the model to treat retrieved text as evidence to cite,
  not commands, (c) do NOT let tool content alter tool-selection logic in the app. Strip/So not execute
  any URLs; the Exa client already filters to http/https only (mined `valid_url?/1`) — replicate to
  block `javascript:`/`data:` URIs from rendering as links in the UI.
- **Output rendering**: assistant markdown is rendered to HTML — sanitize (allowlist) before display to
  prevent stored/reflected XSS from model or web content (sports-fanatic uses `html_sanitize_ex` +
  `earmark`; replicate). Only render http/https links.
- **SSRF / egress**: outbound HTTP is limited to three fixed hosts (`statsapi.mlb.com`,
  `api.anthropic.com`, `api.exa.ai`) plus `baseballsavant` only if Statcast is added later. Do not build
  request URLs from user/model free-text hostnames.
- **DoS / cost runaway**: cap the tool loop at 8 iterations; cap fan-out concurrency; enforce per-tool
  timeouts; the daily-cost projection + per-session cost readout give the operator visibility. Consider
  a soft per-session spend cap (config, default e.g. $5) that pauses further LLM calls — nice-to-have.
- **PII**: none collected; single-user anonymous sessions, no accounts. Session id is a random token,
  not tied to identity.
- **Responsible gambling**: every betting-relevant answer ends with the disclaimer + 1-800-GAMBLER
  (enforced by system prompt; also append server-side as a safety net if missing). The app never places
  bets and states it is research/entertainment only.
- **Container**: runs as non-root `appuser`; minimal runtime image; healthcheck; no secrets baked into
  the image (all via env at runtime).

---

## 14. Implementation Phases (ordered, with acceptance criteria)

**Phase 0 — Project skeleton & infra**
- New Phoenix 1.8 app `mlb_fan` (LiveView, Ecto/Postgres, no Stripe/mailer noise). Add deps (§ versions).
- `docker-compose.yml`, `Dockerfile`, `.env.example`, `config/runtime.exs`, `MlbFan.Release`.
- **Accept**: `mix compile` clean; `docker compose up` boots db + web; `/health` 200; `mix ecto.create`
  works against the compose db.

**Phase 1 — MLB Stats API port + mirror + read-through cache**
- `MlbFan.Stats.Endpoints` registry; `MlbFan.Stats.Api.get/3` with param validation via Req.
- Ecto schemas + migrations (§4.1–4.8). `MlbFan.Cache` (raw_responses, freshness/TTL, keys).
- Parsers for schedule, boxscore, playByPlay HRs, person, stats. `MlbFan.Stats` facade (DB-first).
- **Accept**: unit tests (Req.Test fixtures) prove: schedule/boxscore/homers_by_date populate mirror,
  second identical call served from DB (no HTTP), Final games immutable, schedule short-TTL refresh.
  `homers_by_date/1` returns HRs with batter+pitcher from play-by-play.

**Phase 2 — Streaks**
- `MlbFan.Stats.Streaks.compute/2`; `player_streaks/2` with window box-score ensure-loop.
- **Accept**: all §8.2 edge-case tests green; "7-day hitting streak" and "HR streak" computed purely
  from DB after cache fill.

**Phase 3 — Anthropic client + cost tracking (no MCP yet)**
- `MlbFan.Llm.Anthropic` (Req streaming, adaptive thinking, prompt caching, headers), `Sse` parser,
  `Pricing`, `CostTracker`, `llm_usage` schema. A minimal end-to-end "ask a text question, stream to
  stdout, record cost" path (tools stubbed empty).
- **Accept**: SSE fixture tests pass (incl. chunk-split); NO temperature/top_p/budget_tokens ever sent;
  cost rows exact; cache tokens tracked. Enforced: request omits forbidden fields (unit-assert the body).

**Phase 4 — MCP server + tools + prompts (hermes_mcp)**
- `MlbFan.Mcp.Server` registering all 9 tools + 2 prompts; tool modules delegate to Stats/Research.
- Mount at `/mcp` (Streamable HTTP) per wiring B.
- **Accept**: `tools/list` shows 9 tools with the exact input_schemas; `tools/call` returns correct JSON
  for stubbed Stats; `prompts/list`/`prompts/get` return the two parameterized prompts. (Verify Hermes
  API via `mix hex.docs hermes_mcp` first — see §15 R1.)

**Phase 5 — MCP client + Jido agent + tool loop**
- `MlbFan.Mcp.Client` (connect to local /mcp), `MlbFan.Agent.FanAgent` (Jido), `Loop`, `ToolRouter`,
  `Conversation` GenServer. Full Anthropic tool-use loop routing tool_use → MCP client, concurrent tool
  exec, single tool_result turn, cost per turn.
- **Accept**: integration test (stubbed Anthropic stream emitting tool_use → final) drives a real
  MCP round-trip and produces a final answer; loop cap + timeouts enforced; per-turn `llm_usage` rows.
  (Verify Jido API via `mix hex.docs jido` first — see §15 R2.)

**Phase 6 — Exa research + matchup fan-out**
- `MlbFan.Research.Exa` (mined patterns: retry/backoff, key config, http/https filter), `Matchup`
  (4-angle fan-out via Task.async_stream), `ApiUsage` + `api_usage` schema.
- Wire `research_player_matchup` + `get_matchups_for_players` tools.
- **Accept**: matchup tool returns paired hitter/pitcher w/ stats; research tool returns deduped
  snippets and records `api_usage`; concurrency bounded; Exa fixture tests pass.

**Phase 7 — LiveView chat frontend**
- `ChatLive`: mount posts `Welcome to MLB Fan Agent`, autofocused input, two default buttons (#2 hidden
  until #1 answered), PubSub subscription for streamed deltas, markdown+sanitize render, per-message and
  per-session cost readout, projection widget.
- **Accept**: LiveViewTest confirms welcome string, `autofocus` attr, button gating, streamed append,
  cost badges. Manual: clicking button #1 streams a real answer (with real keys) and shows cost;
  button #2 appears and runs the fan-out.

**Phase 8 — Answer cache + projection polish**
- `answer_cache` (question_key,for_date[,input-set]); serve $0 on same-day repeat; `Cost.Projection`
  daily/monthly figures from observed averages; dashboard what-if across models.
- **Accept**: repeating a default question same day serves cached answer with $0 incremental LLM cost;
  projection widget shows opus/sonnet/haiku monthly estimates.

**Phase 9 — Hardening**
- Security pass (redaction, sanitization, egress allowlist, disclaimer safety-net, optional session
  spend cap); docs (README run instructions); `test.unit` alias; final `mix test` green with no network.
- **Accept**: `mix test` passes offline; `mix credo`/format clean; README lets a fresh user `docker
  compose up` and ask both questions.

---

## 15. Risks & Assumptions (explicit)

- **R1 — `hermes_mcp` (~> 0.14) API surface is version-specific.** The exact behaviours/callbacks for
  defining a server, registering tools/prompts, the Streamable HTTP Plug/router mount, and the client
  API (`tools/list`, `tools/call`, `prompts/get`) MUST be confirmed via `mix hex.docs hermes_mcp` and
  the package source BEFORE Phase 4. Do not assume the shape above (module names like
  `MlbFan.Mcp.Server` are ours; the behaviour/DSL is Hermes'). If Streamable-HTTP mounting differs,
  fall back to wiring A (in-proc/local transport). The tool input_schemas and prompt contents here are
  authoritative regardless of how Hermes wants them registered.
- **R2 — `jido` (~> 2.3) is a large framework.** The user mandates "a Jido agent connecting to an MCP
  server for tool calls and prompts." Confirm via `mix hex.docs jido` whether Jido has first-class MCP
  client support or whether the MCP client is `hermes_mcp`'s client that the Jido agent's actions call.
  The pragmatic, low-risk interpretation (adopt unless Jido docs show a cleaner native path): the Jido
  agent is the orchestration unit; its actions/skills invoke `MlbFan.Mcp.Client` (a `hermes_mcp`
  client). Keep the Anthropic tool-use loop in `MlbFan.Agent.Loop` so the design works even if Jido's
  agent-loop abstraction is thin. The requirement "Jido connects to MCP as a client" is satisfied by the
  Jido agent owning/driving the `hermes_mcp` client.
- **R3 — Anthropic streaming with Req**: confirm the chosen Req streaming mechanism (`into:` callback
  vs `Req.get(into: :self)`) reliably yields SSE chunks; handle events split across TCP chunks in the
  SSE parser (tested in Phase 3). sports-fanatic's Claude client is non-streaming, so streaming is NEW
  code — do not copy its `do_request/1` blindly; reuse only key-resolution + headers.
- **R4 — `claude-opus-4-8` constraints**: adaptive thinking + no sampling params + no budget_tokens are
  hard requirements; a regression here yields 400s. Guard with a unit test asserting the outbound body
  never contains `temperature`/`top_p`/`top_k`/`budget_tokens`.
- **R5 — MLB HR pitcher attribution** requires play-by-play, not just the box score. Box score gives
  per-player HR counts but not "off which pitcher." Use `/api/v1/game/{gamePk}/playByPlay` (or v1.1
  `/feed/live`) and filter `allPlays` where `result.eventType == "home_run"`, taking `matchup.batter`
  and `matchup.pitcher`. This is confirmed by the API's shape; verify field names against a captured
  fixture in Phase 1.
- **R6 — Season/date assumptions**: "current season" derives from today's year (America/New_York). Off-
  season dates will yield empty schedules — handle gracefully (tools return empty with a clear note; the
  model says "no games"). Tests must not depend on live dates.
- **R7 — Req version**: spec pins `req ~> 0.5` to match the proven mined client patterns; `req ~> 0.6`
  is available and acceptable if the coding agent prefers latest — verify streaming API parity first.
- **A1** — Single-user local tool; no auth in v1 (§ Out of Scope).
- **A2** — Exa `type: "auto"` (per user brief) or `"neural"` (mined default) — use `"auto"` as the user
  specified; keep it configurable.
- **A3** — Postgres is the only datastore; no Redis/Valkey.

---

## 16. Chosen Dependency Versions (verified via `mix hex.info` on 2026-07-03)

Add to `mix.exs` deps:
```elixir
{:phoenix, "~> 1.8"},
{:phoenix_live_view, "~> 1.2"},
{:phoenix_ecto, "~> 4.6"},
{:ecto_sql, "~> 3.14"},
{:postgrex, ">= 0.0.0"},
{:phoenix_html, "~> 4.1"},
{:phoenix_live_dashboard, "~> 0.8"},
{:bandit, "~> 1.5"},                 # Phoenix 1.8 default adapter
{:req, "~> 0.5"},                    # HTTP for Anthropic/Exa/MLB (0.6 acceptable — verify streaming)
{:jason, "~> 1.4"},
{:jido, "~> 2.3"},                   # agent framework (mandated)
{:hermes_mcp, "~> 0.14"},            # MCP server + client, Streamable HTTP (mandated)
{:earmark, "~> 1.4"},                # markdown → HTML for chat
{:html_sanitize_ex, "~> 1.4"},      # sanitize model/web output
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.1"},
{:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
{:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
```
Toolchain: **Elixir 1.17 / OTP 27** (matches sports-fanatic's Docker base and Phoenix 1.8 support).

---

## 17. Notes for downstream agents
- **Coder**: Start at Phase 0; before Phase 4/5 run `mix hex.docs hermes_mcp` and `mix hex.docs jido`
  and adjust module wiring to the real APIs (see §15 R1/R2) — the tool schemas, prompts, streak rules,
  cost formulas, and system prompt in this doc are authoritative and should NOT change. Reuse the mined
  Exa/Claude/MLB client patterns (cited paths in §0) for retry, key resolution, headers, and URL safety.
- **Security reviewer**: focus on §13 — key redaction in logs, output sanitization, egress allowlist,
  prompt-injection framing of Exa content, and the responsible-gambling safety-net.
- **Test agent**: enforce zero network egress (Req.Test default that fails un-stubbed requests); the
  streak and SSE parser suites are the highest-value correctness gates.
