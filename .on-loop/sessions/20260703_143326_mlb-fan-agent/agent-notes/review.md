# Reviewer Agent Notes — MLB Fan Agent

## Summary
Holistic production-readiness review of the Elixir/Phoenix 1.8 MLB home-run research agent against the
architect spec, coder notes, security report, and the frozen-artifact/invariant list in `CLAUDE.md`.

The implementation is strong and faithful to the spec. All nine architectural mandates are present and
correctly wired: the MLB-StatsAPI port with a Postgres read-through cache/mirror, the streak algorithms
with the §8.2 edge cases, a streaming raw-HTTP Anthropic client with a boundary-safe SSE parser and the
hard constraint guards (no `temperature`/`top_p`/`top_k`/`budget_tokens`, always `stream:true`,
`thinking:adaptive`, ephemeral `cache_control`), the Hermes MCP server (9 tools + 2 prompts) mounted at
`/mcp`, the Jido agent + tool-use loop, the Exa 4-angle fan-out, the LiveView chat with the exact welcome
string and button labels and the button-2 gating, and the cost model. Security hardening from the
security report is genuinely applied (input clamps, egress allowlist, spend cap, markdown sanitizer +
`<img>` strip, disclaimer safety net). I re-ran the DB-free suite: **166 tests, 0 failures, 42 excluded**.

I found **one MAJOR correctness/cost-model bug**: the Exa `session_id` injected by the `ToolRouter` is
dropped in `ResearchPlayerMatchup.run/1`, so all Exa spend is recorded with `session_id: nil`. This
un-attributes Exa cost per session, makes the Exa portion of the soft spend cap always $0 (weakening a
documented security invariant), and never surfaces Exa spend in the UI cost readout — even though Exa is
the dominant cost of the marquee question #2 per the spec's own projection. Plus a few MINOR/NIT items.

## Verdict: REQUEST_CHANGES

The MAJOR item is a ~1–3 line fix (thread `session_id` through the research tool). Everything else is
excellent. Once Exa spend is attributed to the session, this is an APPROVE.

## Review Checklist Results

### Correctness: ISSUES
- The two default questions, welcome string, exact button labels, and button-2 gating are all correct
  (`chat_live.ex`, `prompts.ex:51-52`). `get_homers_by_date` defaults to yesterday, others to today —
  matches the tool catalog.
- DB-first read-through cache verified: `Cache.fetch_or_fetch/4` is the single choke-point;
  `stats_test` proves a 2nd call is served from the DB with the outbound stub returning 500. Freshness
  policy (immutable Final games, short schedule TTL) is sound.
- Streak algorithm matches §8.2 (walk/HBP-only = skip, ≥1 AB & 0 hit/HR = break, days-off/benched =
  skip, doubleheader order, `window_truncated`). Table-driven tests cover the edge cases.
- **BUG (MAJOR):** `session_id` dropped in `research_player_matchup.ex:20-29` — see Findings.
- MINOR: `Matchup.research` records `units = length(angles)` (4) unconditionally, even when Exa makes no
  network call (missing key / empty results). Over-counts Exa units/cost.
- MINOR: `ensure_home_runs/1` short-circuits on `Repo.exists?` for a game_pk, so a **Live** game's HRs
  are frozen at first ingest and later HRs in that game are never picked up. Fine for the "yesterday /
  Final" default flow; noted for the live path.

### Security: PASS
- Security gate PASSED and I concur. Egress allowlist enforced in dev/prod (`http.ex`), bypassed only by
  the `Req.Test` plug configured solely in `config/test.exs`. Input clamps at both the tool boundary
  (`Params`) and the facade (`Stats.clamp_window/1`, `cap_players/1`) — the `0..window_days` loop is
  bounded. Markdown pipeline is Earmark `escape:true` → HtmlSanitizeEx → drop non-http(s) hrefs → drop
  `<img>`. SQL fully parameterized. Keys resolved from env/config only, never logged. No-auth is
  by-design for a single-user local tool (not flagged).
- Note: the spend-cap invariant (`CLAUDE.md` #5) is *partially* weakened by the MAJOR bug — the cap sums
  `CostTracker.session_total + ApiUsage.session_total`, but the latter is always $0 because Exa rows have
  `session_id: nil`. The cap still fires on LLM spend, so it degrades rather than fails open.

### Performance: PASS
- Tool loop capped at 8; `Task.async_stream` bounds tool concurrency (8) and Exa fan-out (4) with
  per-tool timeouts and `on_timeout: :kill_task`. Streak window bounded ≤ 61 day-fetches.
- Ecto upserts are idempotent with proper conflict targets; indexes match the spec. Money is `Decimal`
  throughout (never float).
- NIT: `#messages` uses `phx-update="replace"` so the full message list (and `Markdown.to_safe_html` on
  done messages) re-renders on each token delta. Fine for a single-user tool; would matter at scale.

### Code Quality: PASS
- Clean context boundaries, cross-context calls go through facades, good moduledocs, typespecs present.
- `mix compile --warnings-as-errors` clean, `mix format` clean, credo (non-strict) exit 0. A few
  credo --strict complexity advisories remain (coder-acknowledged, non-blocking).

### Testing: PASS (one gap)
- 166 tests, 0 failures; DB-free unit suite verified green here. Coverage is strong on the load-bearing
  paths (streaks, SSE chunk-splitting, loop tool_use → final, pricing decimals, cache HIT/MISS/immutable,
  params clamps, egress allowlist, ChatLive gating/cost badge).
- GAP: no test asserts Exa spend is attributed to a session end-to-end (the `ToolRouter` injects
  `session_id` but the research tool discards it — the injection is effectively dead code, and no test
  catches it). Add a test that runs `research_player_matchup` through the router with a session and
  asserts a non-nil `api_usage.session_id`.

### Documentation: PASS
- `CLAUDE.md` is thorough and accurately reflects the module map, frozen artifacts, Anthropic
  constraints, and security invariants. `.env.example`, docker-compose, and run instructions present.

### Build & CI: PASS (advisory)
- Dependencies pinned in `mix.lock`. `mix deps.audit` exits 0; the earmark advisory is mitigated by the
  sanitizer chain and ignored by ID. Dockerfile targets `elixir:1.17-otp-27`. Recommend keeping
  `mix_audit` + adding a projection/cost regression test to CI.

## Issues Found
- [MAJOR] Exa `session_id` dropped in `research_player_matchup.ex:20-29` → Exa spend recorded with
  `session_id: nil`. Breaks per-session Exa cost attribution (spec §10 / G4), zeros the Exa portion of the
  soft spend cap (`conversation.ex:142-145`, `CLAUDE.md` invariant #5), and defeats
  `Projection.observed_exa_avg/1` (which filters `not is_nil(session_id)`, so it always falls back to the
  estimate). Fix: add `session_id: params["session_id"] || params[:session_id]` to the args map passed to
  `Matchup.research/1`.
- [MINOR] Exa cost readout excludes Exa entirely from the UI: `conversation.ex` broadcasts
  `cost = CostTracker.message_total/1` (LLM only) and `ChatLive` accumulates only that into the session
  badge. Exa (~$0.36/run of Q2, roughly half its cost) is never shown. Add `ApiUsage.session_total/1`
  into the surfaced per-session cost (or document the badge as LLM-only).
- [MINOR] `matchup.ex:55-60` records `length(angles)` (4) Exa units even when no network call was made
  (missing key or empty results). Count actual searches performed to keep cost accounting honest.
- [MINOR] `stats.ex:136-164` `ensure_home_runs/1` freezes a Live game's HR set at first ingest (existence
  short-circuit before the cache). Acceptable for the Final-game default flow; revisit for live.
- [NIT] `chat_live.ex:189` `phx-update="replace"` re-renders + re-sanitizes the whole message list on
  each streaming delta.
- [NIT] credo --strict complexity advisories on `Stats.ensure_player_window`/`build_matchup`,
  `Anthropic.apply_event` (coder-acknowledged).

## Decisions
- REQUEST_CHANGES driven solely by the MAJOR Exa-attribution bug: it undermines a mandated feature (the
  cost model, mandate #7 / G4) and weakens a documented security invariant (the spend cap). It is not a
  BLOCKER (no crash, no security regression, `api_usage` rows are still written and LLM cost is fully
  tracked) but it is more than a nit and the fix is trivial.
- No-auth / single anonymous session / 0.0.0.0 bind accepted by design; not flagged.

## Files Reviewed
- `lib/mlb_fan/agent/loop.ex`, `tool_router.ex`, `conversation.ex`, `prompts.ex` — correct; loop cap,
  disclaimer, PubSub streaming, spend cap all wired.
- `lib/mlb_fan/llm/anthropic.ex`, `sse.ex` (via tests), `pricing.ex`, `cost_tracker.ex` — constraint
  guards + decimal cost math correct.
- `lib/mlb_fan/stats/stats.ex`, `streaks.ex`, `parsers.ex` (HR attribution), `cache/cache.ex`,
  `freshness.ex` — DB-first, bounded, HR pitcher attribution via play-by-play correct.
- `lib/mlb_fan/mcp/catalog.ex`, `client.ex`, `params.ex`, `tools/*` — frozen schemas match spec §5;
  clamps applied. **`tools/research_player_matchup.ex` — session_id drop (MAJOR).**
- `lib/mlb_fan/research/matchup.ex`, `exa.ex`, `api_usage.ex` — fan-out + URL safety correct; unit
  over-count (MINOR); session attribution broken by the tool (MAJOR).
- `lib/mlb_fan/cost/projection.ex`, `http.ex`, `application.ex` — correct; egress allowlist enforced.
- `lib/mlb_fan_web/live/chat_live.ex`, `markdown.ex` — welcome/labels/gating/busy-guard correct;
  sanitizer chain intact.

## Commendations
- Excellent SSE parser design (chunk-boundary-safe, tested by 40-byte slicing) and a clean,
  well-guarded Anthropic `build_body/4` with a forbidden-key deep-scan test.
- Defense-in-depth input clamping at both the trust boundary and the facade is exactly right.
- The read-through cache with immutable-Final semantics and a DB-first proof test (stub returns 500 on
  the 2nd call) is a standout.
- Cost model uses `Decimal` end-to-end with cache write/read multipliers matching the spec.
- Frozen-artifact discipline (byte-stable tool schemas + system prompt for prompt caching) is carefully
  maintained and unit-tested.

## Recommendations for Next Agent (coding, if retries remain)
1. **MAJOR fix:** thread `session_id` through `MlbFan.Mcp.Tools.ResearchPlayerMatchup.run/1` into
   `Matchup.research/1` so Exa `api_usage` rows carry the session id. Add an end-to-end test through the
   `ToolRouter` asserting a non-nil `api_usage.session_id` (covers the current dead-code injection).
2. Surface Exa spend in the per-session cost badge (add `ApiUsage.session_total/1`) or document that the
   badge is LLM-only.
3. Record actual Exa searches performed rather than a fixed `length(angles)` when no call is made.
4. (Optional) Consider re-fetching Live-game play-by-play until Final for accurate in-progress HR lists.
