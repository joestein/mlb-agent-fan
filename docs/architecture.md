# Architecture — MLB Fan Agent

## System Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                  Browser (Phoenix LiveView)                         │
│  "Welcome to MLB Fan Agent"  •  autofocused text input              │
│  [⚾ Who homered yesterday — and their HR streaks]                  │
│  [🎯 Who's pitching against them today — and their chances]         │
│  (button 2 hidden until question 1 answered)                        │
│  streaming tokens  •  per-message cost  •  session cost             │
└──────────────────────▲──────────────────────────┬───────────────────┘
                       │ LiveView diffs (PubSub)   │ user event (phx-*)
                       │                           ▼
┌──────────────────────┴───────────────────────────────────────────────┐
│  MlbFanWeb.ChatLive  (LiveView, one process per browser tab)          │
│  • mount: session_id, PubSub subscribe, start Conversation GenServer  │
│  • handle_event: default_1/default_2/submit → Conversation.ask/3     │
│  • handle_info: :assistant_started/:delta/:assistant_done             │
│  • busy guard: ignores events while a turn is in flight               │
└──────────────────────────────────────────┬───────────────────────────┘
                                           │ GenServer.cast {:ask, ...}
                                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  MlbFan.Agent.Conversation  (GenServer, DynamicSupervisor)           │
│  • holds message history (full Anthropic messages list)               │
│  • checks answer_cache for free same-day repeats                      │
│  • checks SESSION_SPEND_CAP_USD before each paid turn                 │
│  • spawns Task → MlbFan.Agent.Loop                                    │
│  • sends {:turn_done, messages} to self, broadcasts cost on done      │
└──────────────────────────────────────────┬───────────────────────────┘
                                           │ Task.start
                                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  MlbFan.Agent.Loop  (Anthropic tool-use loop, max 8 iterations)      │
│  1. build_body (system+tools+messages, stream=true, thinking=adaptive)│
│  2. Anthropic.stream → SSE parser → on_delta broadcasts text tokens   │
│  3. on stop_reason=tool_use: ToolRouter.run (concurrent)              │
│  4. append ONE user msg with ALL tool_results → go to 1               │
│  5. on end_turn: ensure_disclaimer, return text                        │
│  6. CostTracker.record llm_usage row per iteration                    │
└──────┬─────────────────────────────────────────────┬─────────────────┘
       │ Req POST /v1/messages (SSE stream)           │ ToolRouter concurrent dispatch
       ▼                                              ▼
┌──────────────────────┐              ┌───────────────────────────────────┐
│  Anthropic API        │              │  MlbFan.Agent.ToolRouter           │
│  api.anthropic.com    │              │  Task.async_stream (max 8)         │
│  claude-opus-4-8      │              │  tool_timeout 30s / research 60s   │
│  stream + cache       │              └──────────────────┬────────────────┘
└──────────────────────┘                                 │ MlbFan.Mcp.Client.call_tool/2
                                                         │ (default: :direct in-process)
                                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  MlbFan.Mcp.Server  (Hermes, Streamable HTTP at /mcp)                │
│  Tools: get_schedule, get_boxscore, get_homers_by_date,              │
│         get_player_streaks, lookup_player, get_player_stats,         │
│         get_probable_pitchers, get_matchups_for_players,             │
│         research_player_matchup                                       │
│  Prompts: hrs_yesterday_with_streaks, matchup_odds_followup          │
└──────┬──────────────────────────────────────────┬────────────────────┘
       │ Stats tools                               │ research_player_matchup
       ▼                                           ▼
┌──────────────────────────────┐    ┌─────────────────────────────────┐
│  MlbFan.Stats (facade)        │    │  MlbFan.Research.Matchup         │
│  DB-first read-through        │    │  4 angles × Task.async_stream    │
│  ┌──────────┐  ┌──────────┐  │    │  A: recent form                  │
│  │ Postgres  │  │Stats.Api │  │    │  B: pitcher HR risk vs bat side  │
│  │ mirror   │  │(Req)     │  │    │  C: park factor                  │
│  │ raw cache│◄─│statsapi  │  │    │  D: weather/wind forecast         │
│  └──────────┘  │.mlb.com  │  │    └──────────────────┬───────────────┘
│                └──────────┘  │                       │ Req POST
└──────────────────────────────┘                       ▼
                                           ┌──────────────────────┐
                                           │  Exa.ai              │
                                           │  api.exa.ai/search   │
                                           │  num_results=4       │
                                           │  days_back=21        │
                                           └──────────────────────┘
```

---

## Database Tables

All writes use Ecto parameterized queries. All money is stored as `:decimal` (never float). MLB entity IDs are `statsapi` integers stored as `:bigint`.

| Table | Purpose |
|---|---|
| `teams` | MLB team lookup (mlb_id unique key) |
| `players` | Player bio (mlb_id unique key; bat_side, pitch_hand, position) |
| `games` | Game schedule mirror (game_pk unique key; teams, date, state, probable pitchers) |
| `box_scores` | Marker that a game's box score has been ingested (immutable once Final) |
| `batting_lines` | Per-player per-game batting stats — drives streak computation |
| `pitching_lines` | Per-player per-game pitching stats |
| `home_run_events` | One row per home run (batter, pitcher, inning, RBI, description) |
| `raw_responses` | Endpoint + params_hash → raw JSON response + TTL (read-through cache) |
| `llm_usage` | Per-Anthropic-request cost (session, message, tokens, cost_usd, turn_index) |
| `api_usage` | Per-external-API cost (Exa search/contents, units, cost_usd) |
| `answer_cache` | Cached final answers (question_key + date → rendered markdown + cost) |

---

## Data Flow: Default Question 1 (HR Yesterday + Streaks)

```
User clicks "⚾ Who homered yesterday — and their HR streaks"
│
├─ ChatLive.handle_event("default_1")
│   └─ Conversation.ask(session_id, "Today is 2026-07-03. Show everyone ...")
│
├─ Conversation checks answer_cache for ("hrs_yesterday", 2026-07-02)
│   └─ MISS → check spend cap → run_turn
│
├─ Loop iteration 0
│   └─ Anthropic: model reads system prompt + 9 tool defs + user turn
│   └─ stop_reason = "tool_use"
│       ├─ tool_use: get_homers_by_date {date: "2026-07-02"}
│       └─ tool_use: (sometimes) get_schedule for context
│
├─ ToolRouter runs tool(s) concurrently
│   └─ get_homers_by_date:
│       ├─ Stats.homers_by_date("2026-07-02")
│       ├─ Cache.fetch_or_fetch("home_run_events", params)
│       │   └─ HIT? read home_run_events WHERE game_date = ...
│       │   └─ MISS? schedule(date) → game_pk list → playByPlay per game
│       │         → parse HRs → insert home_run_events + batting_lines
│       └─ return {count: 27, home_runs: [{batter, pitcher, inning, rbi}, ...]}
│
├─ Loop iteration 1
│   └─ Anthropic: now has HR list → decides to call get_player_streaks
│   └─ stop_reason = "tool_use"
│       └─ tool_use: get_player_streaks {player_mlb_ids: [658668, 681911, ...]}
│
├─ ToolRouter
│   └─ get_player_streaks:
│       ├─ Params.window/id_list → clamp to [1,60] days, ≤25 ids
│       ├─ Stats.player_streaks(ids, window: 30)
│       │   └─ ensure_player_window: for each player's team, scan 30 days
│       │       of games — fill any missing batting_lines from boxscore API
│       └─ Streaks.compute: walk newest→oldest over batting_lines
│           edge cases: walk/HBP-only games skip, benched skips, DH ordered
│           → {hr_streak: 3, hitting_streak: 8, last_hr_date: "2026-07-01"}
│
├─ Loop iteration 2
│   └─ Anthropic: synthesizes markdown table sorted by HR streak desc
│   └─ stop_reason = "end_turn"
│
├─ ensure_disclaimer → append gambling note if absent
├─ CostTracker.message_total → cost_usd
├─ answer_cache.put("hrs_yesterday", 2026-07-02, text, cost)
└─ broadcast {:assistant_done, message_id, text, %{cost_usd, input, output}}
```

---

## Data Flow: Default Question 2 (Matchups + Chances)

```
User clicks "🎯 Who's pitching against them today — and their chances"
│
├─ ChatLive.handle_event("default_2") — only available after Q1 answered
│   └─ Conversation.ask(session_id, "Today is 2026-07-03. From the players ...")
│
├─ Loop iteration 0
│   └─ Anthropic: system prompt + 9 tool defs + Q1 answer in history + Q2 question
│   └─ stop_reason = "tool_use"
│       └─ tool_use: get_matchups_for_players {player_mlb_ids: [...], date: "2026-07-03"}
│
├─ ToolRouter
│   └─ get_matchups_for_players:
│       ├─ Params.id_list → cap to 25 ids
│       ├─ Stats.matchups_for_players(ids, date)
│       │   For each hitter:
│       │   ├─ lookup player's current_team_mlb_id
│       │   ├─ schedule(date) → find game for that team
│       │   ├─ extract opposing probable pitcher (home/away by team)
│       │   ├─ player_stats(hitter, group: "hitting") → HR, AVG, SLG, bat_side
│       │   └─ player_stats(pitcher, group: "pitching") → ERA, WHIP, HR/9
│       └─ return [{hitter: {..., season: {...}}, opponent_pitcher: {...}}, ...]
│           or {hitter, no_game: true} for off-day players
│
├─ Loop iteration 1
│   └─ Anthropic: sees hitter↔pitcher pairs → emits N research_player_matchup calls
│   └─ stop_reason = "tool_use"
│       ├─ tool_use: research_player_matchup {hitter_name: "Aaron Judge", ...}
│       ├─ tool_use: research_player_matchup {hitter_name: "Kyle Schwarber", ...}
│       └─ ... (one per hitter, all in the same turn)
│
├─ ToolRouter runs all N research tools concurrently (max 8)
│   Each research_player_matchup:
│   ├─ Research.Matchup.research(args)
│   ├─ Build 4 angles (A: recent form, B: pitcher HR risk, C: park, D: weather)
│   ├─ Task.async_stream(angles, max_concurrency: 4, timeout: 20s)
│   │   Each angle: Exa.search(query, num_results: 4, days_back: 21)
│   │              → filter http/https URLs → dedup_by_domain(2) → take 3
│   ├─ ApiUsage.record_exa("search", 4, meta, session_id)
│   └─ return {hitter, pitcher, snippets: [{angle, title, url, text}, ...]}
│
├─ Loop iteration 2
│   └─ Anthropic: synthesizes all snippets per hitter
│       For each: CONFIDENCE 1-10, 2-4 grounded bullets, cited URLs
│       ranked table best→worst, responsible-gambling note
│   └─ stop_reason = "end_turn"
│
└─ ensure_disclaimer → answer_cache.put → broadcast done
```

---

## OTP Supervision Tree

```
MlbFan.Supervisor (one_for_one)
├── MlbFanWeb.Telemetry
├── MlbFan.Repo  (Ecto, Postgres pool)
├── DNSCluster
├── Phoenix.PubSub (name: MlbFan.PubSub)
├── Registry (name: MlbFan.ChatRegistry, keys: :unique)
├── DynamicSupervisor (name: MlbFan.ConversationSupervisor)
│   └── [MlbFan.Agent.Conversation per session_id, on demand]
├── Hermes.Server.Registry  (must start before MCP server)
├── MlbFan.Mcp.Server  (transport: :streamable_http)
└── MlbFanWeb.Endpoint  (Bandit HTTP server)
```

Each browser tab creates one `Conversation` GenServer (via `ensure_started/1`) under the `DynamicSupervisor`, identified by a random `session_id` string.

---

## MCP Wiring

The app uses wiring (B) from the architect spec: the Hermes server is mounted in the Phoenix router at `/mcp` and is also reachable by external clients (e.g. Claude Desktop).

Internal tool dispatch uses `:direct` mode by default — `MlbFan.Mcp.Client.call_tool/2` invokes the tool component's `run/1` function in-process. This avoids a self-HTTP loop, keeps the test suite fully offline, and is equivalent in behavior to a real MCP call.

To use a genuine MCP round-trip internally (`:hermes` mode), set `config :mlb_fan, :mcp_dispatch, :hermes` and ensure `MlbFan.Mcp.HermesClient` is started with the correct `:streamable_http` transport.

---

## Prompt Caching Strategy

The system prompt (`MlbFan.Agent.Prompts.system/0`) and the 9 tool definitions (`MlbFan.Mcp.Catalog.anthropic_tools/0`) are both byte-stable compile-time constants. They are sent together in a single system block with `"cache_control": {"type": "ephemeral"}`. On the first request per Anthropic billing period, Anthropic writes ~2K tokens to the prompt cache (charged at 1.25× input rate). All subsequent requests in the same session (and across sessions on the same day) read from cache at 0.10× input rate — a ~5× discount on the fixed portion of every request.

"Today's date" and dynamic user questions are injected only in user-turn messages, never in the system block, to preserve byte-stability.
