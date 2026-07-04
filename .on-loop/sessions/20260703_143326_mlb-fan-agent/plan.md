# Implementation Plan: MLB Fan Agent

Derived from `agent-notes/architect.md` (authoritative). Coding agent implements phases in order
inside the worktree `.claude/worktrees/mlb-fan-agent`.

## What we're building
Elixir/Phoenix 1.8 app (`mlb_fan`) for daily MLB home-run betting research:
- Elixir port of the MLB-StatsAPI Python library (ENDPOINTS registry + Req) — spec §3/§5
- Postgres read-through cache/mirror (11 schemas incl. raw_responses TTL cache) — spec §4
- Hermes MCP server at `/mcp` with 9 tools + 2 prompts — spec §5
- Jido agent driving an Anthropic (claude-opus-4-8, raw HTTP/Req, streaming SSE, adaptive
  thinking, prompt caching) tool-use loop through the MCP client — spec §6
- Exa.ai matchup research fan-out (4 angles/hitter, Task.async_stream) — spec §9
- LiveView chat: "Welcome to MLB Fan Agent", autofocus, 2 default question buttons (#2 gated),
  streaming, per-message/session cost readout — spec §7
- Cost model: llm_usage + api_usage + answer_cache tables, pricing map, projections — spec §10
- docker compose (postgres:16 + mix release), .env.example — spec §11

## Phase order (spec §14 — acceptance criteria there are the gate)
0. Skeleton + infra (compose, Dockerfile, runtime.exs, Release)
1. Stats API port + mirror + read-through cache
2. Streak algorithms (all §8.2 edge cases)
3. Anthropic client + SSE parser + cost tracking (guard test: never send temperature/top_p/top_k/budget_tokens)
4. MCP server + tools + prompts (VERIFY hermes_mcp API via hex docs first — R1)
5. MCP client + Jido agent + tool loop (VERIFY jido API first — R2)
6. Exa research + matchup fan-out
7. LiveView chat frontend
8. Answer cache + cost projection
9. Hardening (security pass, README, test.unit alias, offline `mix test` green)

## Key risks the coder must handle
- R1/R2: hermes_mcp ~>0.14 and jido ~>2.3 real API surfaces — check hex docs/source before wiring;
  tool schemas/prompts/streaks/cost formulas/system prompt are frozen regardless.
- R3: Req SSE streaming is new code (sports-fanatic client is non-streaming); parser must handle
  events split across TCP chunks.
- R5: HR pitcher attribution needs playByPlay, not boxscore.

## Pipeline gates after CODE
- TEST: full `mix test` offline (Req.Test, zero egress), streak + SSE suites highest value; ≤3 retries
- SECURITY: §13 focus (key redaction, sanitized markdown, egress allowlist, prompt-injection framing,
  gambling disclaimer safety-net); ≤2 retries
- DOC + BUILD in parallel; REVIEW ≤2 retries; then commit → push → PR
