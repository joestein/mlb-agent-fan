# Documentation Agent Notes

## Summary

Produced three documentation files and rewrote one existing file for the MLB Fan Agent worktree. All content was verified against the live source code (config/runtime.exs, mix.exs, lib/**, docker-compose.yml, .tool-versions) — no aspirational features were documented.

## Decisions

- **README.md rewritten** (the coding agent's version was a good skeleton but lacked the environment variables table, cost model detail, two-question explanation, troubleshooting section, and the responsible-gambling note required by the task). The rewrite keeps every accurate statement from the original and adds the missing content.
- **CLAUDE.md created** with a full module map, the frozen-artifact table (tool schemas, system prompt, button labels, welcome string, streak rules, cost formula, pricing map, egress allowlist, input clamps), the hard Anthropic constraints, security invariants, file structure, and common tasks. Written to be actionable for a future Claude Code session without re-reading the full spec.
- **docs/architecture.md created** with the full ASCII system diagram, per-table DB summary, two detailed data-flow traces (Q1 and Q2), the OTP supervision tree, and the prompt-caching strategy section.
- **docs/mcp-tools.md created** cataloging all 9 tools and 2 prompts with exact input schemas (taken verbatim from MlbFan.Mcp.Catalog), backing functions, API endpoints, trust-boundary clamping notes, and annotated example return shapes. Also documents how to connect an external MCP client.
- Environment variable table uses `runtime.exs` as the canonical source. `POSTGRES_PASSWORD` is documented as docker-compose-only (not in runtime.exs directly). `SESSION_SPEND_CAP_USD` is included even though it was absent from `.env.example`.
- Security notes in README document the earmark advisory and its mitigation accurately (per security.md verdict: "advisory-only, mitigated, not exploitable as wired").

## Files Modified

- `/Users/charmalloc/dev/mlb-agent-fan/.claude/worktrees/mlb-fan-agent/README.md` — full rewrite: what-it-is + gambling note, architecture overview, prerequisites, Docker quickstart, local dev quickstart, env vars table, two-question explanation + caching, cost model table, MCP tool list, security notes, troubleshooting.
- `/Users/charmalloc/dev/mlb-agent-fan/.claude/worktrees/mlb-fan-agent/CLAUDE.md` — created: module map, frozen artifacts table, Anthropic constraints, security invariants, file structure, common tasks.
- `/Users/charmalloc/dev/mlb-agent-fan/.claude/worktrees/mlb-fan-agent/docs/architecture.md` — created: full ASCII system diagram, DB table summary, Q1/Q2 data-flow traces, OTP supervision tree, MCP wiring note, prompt-caching strategy.
- `/Users/charmalloc/dev/mlb-agent-fan/.claude/worktrees/mlb-fan-agent/docs/mcp-tools.md` — created: all 9 tools + 2 prompts with input schemas, backing functions, return shapes, trust-boundary clamp notes, external client connection guide.

## Issues Found

- [INFO] `.env.example` is missing `SESSION_SPEND_CAP_USD` and `POSTGRES_PASSWORD`. Both are now documented in the README env vars table. A future pass could add them to `.env.example` for discoverability.
- [INFO] `EXA_SEARCH_TYPE` appears in `.env.example` as `EXA_SEARCH_TYPE` and in `runtime.exs` as `EXA_SEARCH_TYPE` feeding `config :mlb_fan, :exa, type:`. It is not listed in the task's required env var set, so it is documented as an optional detail.

## Recommendations for Next Agent

- Add `SESSION_SPEND_CAP_USD` and `POSTGRES_PASSWORD` to `.env.example` for operator discoverability.
- Consider adding `mix credo --strict` output to CI alongside `mix deps.audit`; the coding notes mention a handful of advisory complexity suggestions in `Stats.ensure_player_window`, `Stats.build_matchup`, and `Anthropic.apply_event` that are candidates for extraction.
- The `answer_cache` `input_hash` column is reserved but unused (keying Q2 by input hitter-id set is a planned enhancement per coding notes).
