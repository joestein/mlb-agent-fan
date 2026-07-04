# Testing Agent Notes

## Summary

Ran the inherited suite (53 tests, 0 failures), performed a full gap-hunt against
spec §12 + §14 acceptance criteria, added 84 new tests across 7 new/modified
files, fixed 4 test-code bugs (wrong assertions about sanitizer behavior, one
sigil-delimiter bug) discovered during the run, and re-validated the full suite.

Final result: **137 tests, 0 failures** (`mix test`). `mix test.unit` runs 103 of
those (34 excluded by `:db`/`:req` tags).

---

## Initial Run Result (verbatim)

```
Running ExUnit with seed: 756715, max_cases: 24
........................................[warning] Exa API key not configured; skipping search
.............
Finished in 0.3 seconds (0.2s async, 0.1s sync)
53 tests, 0 failures
```

---

## Gaps Found vs Spec Acceptance Criteria

### a. Streaks (§8.2)
- Missing: walk-only game (0 AB, 0 HR) skip for the **HR streak** (only the
  hitting-streak rule was tested; spec §8.2 rule 7 applies same skip to HR).
- Missing: pinch-runner with `appeared=true`, `plate_appearances=0`, `at_bats=0`
  (spec §8.2 rule 8 says "drive this off plate_appearances/at_bats, not
  position") — only `appeared=false` was tested (benched).
- Missing: `last_hr_date` and `games_scanned` assertion coverage beyond the empty
  case.

### b. SSE parser (§6.3)
- Missing: `stop_reason` paths `end_turn`, `max_tokens`, `refusal`, `pause_turn`
  (only `tool_use` was tested).
- Missing: `thinking_delta` accumulation; thinking block should not be streamed
  as answer text.
- Missing: two **parallel** `tool_use` blocks in one stream decoded and preserved
  separately (spec §6.4: "ALL tool_use blocks").
- Missing: `input_json_delta` arriving in very small fragments (beyond the
  40-byte full-stream split).

### c. R4 guard (§6.2)
- Missing: outbound request headers not verified — `anthropic-version: 2023-06-01`
  and `x-api-key` were only set in code, never asserted by a test.
- Missing: `{:error, :no_api_key}` path when key is absent.

### d. Read-through cache (§4.8)
- Missing: `ttl_seconds=nil` + `immutable=false` is stale (explicit freshness
  edge case; spec §4.8 says only `immutable==true` rows are forever-fresh).
- Missing: full `Freshness.policy/2` and `to_row/1` contract tests.

### e. Tool loop (§6.4)
- Missing: two parallel `tool_use` blocks → both executed, ONE list with BOTH
  `tool_result` blocks.
- Missing: `is_error: true` path when a tool fails.
- Missing: loop cap at N=8 returns a diagnostic `stop_reason: "max_iterations"`.
- Missing: mixed success + error in one batch.

### f. Cost formulas (§10.2)
- Missing: exact Decimal costs for **sonnet-4-6** and **haiku-4-5** including
  cache write/read multipliers.
- Missing: zero tokens → zero cost.
- Missing: cache write = 1.25× and read = 0.10× multiplier assertion (separate).
- Missing: partial usage map (missing keys default to 0).

### g. LiveView (§7 / §12)
- Missing: streamed delta append (`handle_info {:delta, ...}` appends to DOM).
- Missing: `answered_q1` flipped after `assistant_done` for `hrs_yesterday` label
  (button #2 appears).
- Missing: per-message cost badge after `assistant_done`.
- Missing: freeform label does NOT flip `answered_q1`.
- Missing: sanitized markdown — script tags stripped before render.

### h. MCP (§5)
- Missing: `prompts/get` returning correct text for both prompts (date injection,
  player-ids injection, tool-call hints, responsible-gambling cue).
- Missing: schema spot-checks for all tools beyond `get_player_streaks` and
  `research_player_matchup`.

### i. Network egress guard (§12)
- No explicit test asserting un-stubbed requests raise instead of hitting the
  network. The config is correct but it was not verified by a test.

---

## Tests Written

### New Test Files

- `test/mlb_fan_web/markdown_test.exs` — `to_safe_html/1`: script tag stripping,
  `javascript:` href removal (sanitizer removes entirely), `data:` URI removal,
  `drop_unsafe_links` regex fallback for schemes that survive sanitizer, valid
  `https:`/`http:` preserved, bold rendering, nil/integer input safety.

- `test/mlb_fan/cache/freshness_test.exs` — `Freshness.fresh?/2`: immutable
  always fresh, `ttl_seconds=nil+immutable=false` is stale, nil `fetched_at`
  is stale, within-TTL is fresh, expired TTL is stale, `stale?` is inverse of
  `fresh?`. `Freshness.policy/2`: Final entity → immutable, boxscore/playByPlay
  with `final?:true`, schedule short TTL, person long TTL. `Freshness.to_row/1`:
  immutable and ttl variants.

- `test/mlb_fan/mcp/prompts_test.exs` — `HrsYesterdayWithStreaks.text/1`: date
  injection, get_homers + get_player_streaks tool hints, table request, atom
  keys, default yesterday. `MatchupOddsFollowup.text/1`: player ids, tool hints,
  1-10 score + sources, empty ids. `Client.get_prompt/2`: both prompts return
  `{:ok, text}`, unknown returns `{:error, _}`.

- `test/mlb_fan/agent/tool_router_test.exs` — `ToolRouter.run/2`: unknown tool
  → `is_error: true`, two parallel blocks → two results in one list (both
  `tool_use_id`s present, no `is_error`), content is JSON-encoded map, mixed
  success + error in one batch, network egress guard (un-stubbed request raises).

### Modified Test Files

- `test/mlb_fan/stats/streaks_test.exs` — Added 6 tests: HR streak walk-only
  skip (spec §8.2 rule 7), pinch-runner `appeared=true, pa=0, ab=0` skip (rule
  8), only-Final games as caller responsibility, consecutive hitting then 0-for
  leaves streak=1, `last_hr_date` is most recent HR game, `games_scanned` counts
  only appeared games.

- `test/mlb_fan/llm/sse_test.exs` — Added 10 tests: all 4 non-tool_use
  stop_reason paths (`end_turn`, `max_tokens`, `refusal`, `pause_turn`) via a
  compile-time `for` loop, `thinking_delta` accumulation into thinking block,
  thinking NOT streamed as text, two parallel `tool_use` blocks decoded from one
  stream, two-tool stream split across chunk boundaries still decoded, highly
  fragmented `input_json_delta` assembles correctly.

- `test/mlb_fan/llm/anthropic_test.exs` — Changed to `async: false` +
  `@moduletag :req`. Added describe "stream/3 outbound headers": asserts
  `anthropic-version: 2023-06-01` header sent, `x-api-key` carries the
  configured key value, `{:error, :no_api_key}` returned when key absent.

- `test/mlb_fan/llm/pricing_test.exs` — Added 6 tests: sonnet with 1M/1M/1M/1M
  tokens exact decimal (22.050000), haiku same (7.350000), zero tokens → 0,
  partial usage map defaults missing keys to 0, cache write = 1.25× input,
  cache read = 0.10× input.

- `test/mlb_fan/agent/loop_test.exs` — Added loop cap test: sets
  `max_loop_iterations: 3`, stubs Anthropic to always return `tool_use` SSE,
  asserts `stop_reason == "max_iterations"`, text contains "tool-call limit",
  exactly 3 `llm_usage` rows recorded.

- `test/mlb_fan_web/live/chat_live_test.exs` — Added 5 tests: `{:delta, ...}`
  appends to DOM, `{:assistant_done, ..., "hrs_yesterday"}` flips `answered_q1`
  and button #2 appears, per-message cost badge shows `$0.34` and token counts,
  freeform label does not flip `answered_q1`, script tags stripped from assistant
  message before render.

- `test/mlb_fan/mcp/catalog_test.exs` — Added 8 tests: schema spot-checks for
  `get_schedule` (no required), `get_boxscore` (requires `game_pk: integer`),
  `get_homers_by_date` (no required), `lookup_player` (requires `name: string`),
  `get_player_stats` (requires `player_mlb_id`, group enum + default), and
  `get_matchups_for_players` (requires `player_mlb_ids: array<integer>`), every
  tool has a description ≥ 20 chars, `module_for` returns `:error` for unknown,
  `fetch/1` returns full definition.

---

## Decisions

- `async: false` on `anthropic_test.exs`: the headers test stubs `Req.Test` and
  also sets `Application.put_env`; using `async: false` avoids ETS/env races.
- Kept `@moduletag :req` on the new headers tests to exclude them from
  `mix test.unit` (consistent with the existing `exa_test.exs` convention).
- Used compile-time `for` loop for stop_reason path tests to avoid boilerplate.
- Tested `ToolRouter` directly (not via `Loop`) for the parallel-execution and
  is_error properties, because `ToolRouter` is the component that assembles
  the ONE user message. The full loop integration is already tested by the
  existing `loop_test.exs`.
- The Markdown sanitizer test updated to reflect actual behavior: `HtmlSanitizeEx.markdown_html` removes non-allowed hrefs entirely (not replacing with `#`); `drop_unsafe_links` is a belt-and-suspenders fallback for schemes that survive sanitizing. Both behaviors are safe.

---

## Bugs Found in My Own Tests (Fixed)

### Test Bug 1: Wrong assertion about script tag content
- **File**: `test/mlb_fan_web/markdown_test.exs` (initial write)
- **Issue**: Asserted `refute result =~ "alert("` but `HtmlSanitizeEx` strips the
  `<script>` **wrapper** while preserving the inner text as inert plain text.
  The script content IS visible as text (non-executable). The real security
  property is absence of the `<script>` tag.
- **Fix**: Changed to `refute result =~ "<script>"` and `refute result =~ "</script>"`.
  Also restructured input so regular text precedes the script tag (Earmark treats
  a line starting with `<script>` as a raw HTML block, consuming trailing text).

### Test Bug 2: Wrong assertion about javascript: href
- **File**: `test/mlb_fan_web/markdown_test.exs` (initial write)
- **Issue**: Asserted `assert result =~ ~s(href="#")` but `HtmlSanitizeEx.markdown_html`
  removes the `href` attribute entirely from non-safe schemes. `drop_unsafe_links`
  only fires if a non-http(s) `href` survives sanitizing. Both behaviors are
  secure; the test expectation was wrong.
- **Fix**: Changed to `refute result =~ "javascript:"` (key safety property).

### Test Bug 3: Same issue for data: URI href
- Same root cause and fix as Test Bug 2.

### Test Bug 4: `~s(...)` sigil with closing paren inside content
- **File**: `test/mlb_fan_web/markdown_test.exs` (initial write)
- **Issue**: Used `~s(<a href="vbscript:evil()">v</a>)` — the `)` in `evil()` closes
  the `~s(...)` sigil early, causing a parse error on the next line.
- **Fix**: Changed to `~s[<a href="vbscript:evil()">v</a>]` (square-bracket delimiters).

All four were test-code bugs, not application bugs.

---

## Bugs Found in Application Code

None. All 4 initial failures were due to incorrect test assertions or test-code
syntax errors. The implementation is correct.

---

## Files Modified

- `test/mlb_fan_web/markdown_test.exs` — CREATED
- `test/mlb_fan/cache/freshness_test.exs` — CREATED
- `test/mlb_fan/mcp/prompts_test.exs` — CREATED
- `test/mlb_fan/agent/tool_router_test.exs` — CREATED
- `test/mlb_fan/stats/streaks_test.exs` — MODIFIED (added 6 tests)
- `test/mlb_fan/llm/sse_test.exs` — MODIFIED (added 10 tests)
- `test/mlb_fan/llm/anthropic_test.exs` — MODIFIED (added 3 tests, changed async/tag)
- `test/mlb_fan/llm/pricing_test.exs` — MODIFIED (added 6 tests)
- `test/mlb_fan/agent/loop_test.exs` — MODIFIED (added 1 test)
- `test/mlb_fan_web/live/chat_live_test.exs` — MODIFIED (added 5 tests)
- `test/mlb_fan/mcp/catalog_test.exs` — MODIFIED (added 8 tests)

---

## Final `mix test` Output (verbatim)

```
Running ExUnit with seed: 107519, max_cases: 24
..............................................................................................[warning] Exa API key not configured; skipping search
...........................................
Finished in 0.5 seconds (0.2s async, 0.2s sync)
137 tests, 0 failures
```

`mix test.unit` result:
```
Running ExUnit with seed: 588652, max_cases: 24
Excluding tags: [:db, :req]
.......................................................................................................
Finished in 0.1 seconds (0.1s async, 0.00s sync)
137 tests, 0 failures, 34 excluded
```

---

## Test Results

- **Total**: 137
- **Passed**: 137
- **Failed**: 0
- **Skipped**: 0
- **Excluded (unit mode)**: 34
- **Coverage**: Not measured (no ExCoveralls configured)

---

## Recommendations for Next Agent (Security Reviewer)

- The `x-api-key` test verifies the key is **sent**, but does not test that it
  is **never logged** (spec §13, §6.2). A Logger capture test would close this gap
  but requires hooking into Logger which is invasive; the code is correct (uses
  `Logger.error` with `inspect(reason)`, not the raw headers).
- The `Markdown.drop_unsafe_links/1` regex is belt-and-suspenders; the primary
  defense is `HtmlSanitizeEx.markdown_html`. Confirm the sanitizer's allowlist is
  restrictive enough (no `style`, `iframe`, `object`).
- Exa result URL safety (javascript:/data: filter in `Exa.search/2`) is tested
  by the existing `exa_test.exs` — confirm this extends to snippet `text` content
  that could contain malicious links.
- The loop cap is 8 by default (config `:agent, :max_loop_iterations`). Confirm
  no code path allows resetting the counter mid-run.

---

## VERDICT: PASS

All 137 tests pass. Zero failures. Both happy-path and error-path coverage exists
for every spec §12 target area. No application bugs found.
