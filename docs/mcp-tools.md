# MCP Tools & Prompts Reference

The Hermes MCP server (`MlbFan.Mcp.Server`) is mounted at `/mcp` (Streamable HTTP). All dates use ISO 8601 (`YYYY-MM-DD`) in tool I/O. All tools return JSON objects. Integer inputs are coerced and clamped at the trust boundary by `MlbFan.Mcp.Params` before reaching `MlbFan.Stats`.

---

## Tools

### `get_schedule`

Retrieve the MLB game schedule for a date.

**Description:** "Get the MLB game schedule for a date, including teams, status, venue, and probable starting pitchers. Use to find which games are played on a given day."

**Backing module:** `MlbFan.Mcp.Tools.GetSchedule`
**Backing function:** `MlbFan.Stats.schedule(date, hydrate: [:probablePitcher, :linescore, :venue, :team])`
**API endpoint:** `statsapi.mlb.com/api/v1/schedule`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "date": {
      "type": "string",
      "description": "ISO date YYYY-MM-DD. Defaults to today (America/New_York)."
    }
  },
  "required": []
}
```

**Returns:** Object with `date`, `game_count`, and `games` list (game_pk, teams, state, venue, probable pitchers).

---

### `get_boxscore`

Get the full box score for a single game.

**Description:** "Get the full box score for a single game by its gamePk: per-player batting and pitching lines for both teams."

**Backing module:** `MlbFan.Mcp.Tools.GetBoxscore`
**Backing function:** `MlbFan.Stats.boxscore(game_pk)`
**API endpoint:** `statsapi.mlb.com/api/v1/game/{game_pk}/boxscore`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "game_pk": {
      "type": "integer",
      "description": "MLB gamePk from the schedule."
    }
  },
  "required": ["game_pk"]
}
```

**Returns:** Object with `game_pk`, `home` and `away` sections (team info, batting lines, pitching lines per player).

---

### `get_homers_by_date`

List every home run hit on a given date across MLB.

**Description:** "List every home run hit on a given date across MLB, with the batter, the pitcher who allowed it, the teams, inning, and RBIs. Use for 'who hit a home run yesterday'."

**Backing module:** `MlbFan.Mcp.Tools.GetHomersByDate`
**Backing function:** `MlbFan.Stats.homers_by_date(date)`
**DB table:** `home_run_events` (fills lazily from schedule → `playByPlay` API on miss)
**API endpoints:** `statsapi.mlb.com/api/v1/schedule`, `.../game/{game_pk}/playByPlay`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "date": {
      "type": "string",
      "description": "ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York)."
    }
  },
  "required": []
}
```

**Returns:**
```json
{
  "date": "2026-07-02",
  "count": 27,
  "home_runs": [
    {
      "batter": {"mlb_id": 658668, "name": "Aaron Judge", "team": "NYY"},
      "pitcher": {"mlb_id": 621111, "name": "Shane Baz", "team": "TB"},
      "inning": 3,
      "half": "top",
      "rbi": 1,
      "game_pk": 748219,
      "description": "Aaron Judge homers (21) on a fly ball to left field."
    }
  ]
}
```

---

### `get_player_streaks`

Compute current HR and hitting streaks for one or more players.

**Description:** "For one or more players, compute their current home-run streak and hitting streak over the last N team games. HR streak = consecutive team games with at least one HR by the player. Hitting streak = consecutive games with at least one hit. Days off do not break a streak."

**Backing module:** `MlbFan.Mcp.Tools.GetPlayerStreaks`
**Backing function:** `MlbFan.Stats.player_streaks(ids, window_days: n, as_of: date)`
**Trust-boundary clamps:** `window_days` → `[1, 60]` (default 30); `player_mlb_ids` → ≤25 ids

**Streak rules (spec §8.2):**
- Streaks are over team games the player appeared in, not calendar days.
- Walk/HBP-only appearances (0 AB, 0 H/HR) are skipped — neither extend nor break.
- Benched/did-not-play games are skipped.
- Doubleheaders: each game counts independently, ordered by `(game_date, game_pk)`.
- `window_truncated: true` if the streak reaches the scan boundary.

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "player_mlb_ids": {
      "type": "array",
      "items": {"type": "integer"},
      "description": "MLB person ids."
    },
    "window_days": {
      "type": "integer",
      "default": 30,
      "description": "How many days of game logs to scan back."
    },
    "as_of_date": {
      "type": "string",
      "description": "ISO date; streak computed as of end of this day. Defaults to today."
    }
  },
  "required": ["player_mlb_ids"]
}
```

**Returns:**
```json
{
  "as_of": "2026-07-03",
  "players": [
    {
      "mlb_id": 658668,
      "name": "Aaron Judge",
      "hr_streak": 3,
      "hitting_streak": 8,
      "last_hr_date": "2026-07-02",
      "games_scanned": 27,
      "window_truncated": false
    }
  ]
}
```

---

### `lookup_player`

Resolve a player name to their MLB person id and bio.

**Description:** "Resolve a player name to their MLB person id and basic bio (position, bats/throws, team). Use before other tools when you only have a name."

**Backing module:** `MlbFan.Mcp.Tools.LookupPlayer`
**Backing function:** `MlbFan.Stats.lookup_player(name)`
**API endpoint:** `statsapi.mlb.com/api/v1/people/search?names=...`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Full or partial player name."
    }
  },
  "required": ["name"]
}
```

**Returns:** Object with `players` list, each entry: `mlb_id`, `full_name`, `primary_position`, `bat_side`, `pitch_hand`, `current_team`.

---

### `get_player_stats`

Get a player's season hitting or pitching stats.

**Description:** "Get a player's season hitting or pitching stats for a given season and group."

**Backing module:** `MlbFan.Mcp.Tools.GetPlayerStats`
**Backing function:** `MlbFan.Stats.player_stats(id, group: g, season: y)`
**API endpoint:** `statsapi.mlb.com/api/v1/people/{id}/stats?stats=season&group=...`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "player_mlb_id": {"type": "integer"},
    "group": {
      "type": "string",
      "enum": ["hitting", "pitching"],
      "default": "hitting"
    },
    "season": {
      "type": "integer",
      "description": "4-digit year. Defaults to current season."
    }
  },
  "required": ["player_mlb_id"]
}
```

**Returns:** Object with `mlb_id`, `season`, `group`, and `stats` map (hitting: avg, hr, rbi, slg, obp, iso; pitching: era, whip, k9, hr9, bb9, innings_pitched).

---

### `get_probable_pitchers`

List probable starting pitchers for a date.

**Description:** "For a date, list each game's probable starting pitchers (home and away) with ids and hands. Use to find who a hitter's team faces today."

**Backing module:** `MlbFan.Mcp.Tools.GetProbablePitchers`
**Backing function:** `MlbFan.Stats.probable_pitchers(date)` (schedule with `probablePitcher` hydration)
**API endpoint:** `statsapi.mlb.com/api/v1/schedule?hydrate=probablePitcher,...`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "date": {
      "type": "string",
      "description": "ISO date YYYY-MM-DD. Defaults to today."
    }
  },
  "required": []
}
```

**Returns:** Object with `date` and `games` list, each game entry: `game_pk`, `home_team`, `away_team`, `home_probable` / `away_probable` (mlb_id, name, pitch_hand), `venue`.

---

### `get_matchups_for_players`

Pair hitters with today's opposing probable starting pitcher (used for default question 2).

**Description:** "Given a list of hitters, find today's game for each hitter's team and the opposing probable starting pitcher. Returns hitter→opponent-pitcher pairs with basic stats for both."

**Backing module:** `MlbFan.Mcp.Tools.GetMatchupsForPlayers`
**Backing function:** `MlbFan.Stats.matchups_for_players(ids, date)`
**Trust-boundary clamps:** `player_mlb_ids` → ≤25 ids (graceful truncation note on overflow)

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "player_mlb_ids": {
      "type": "array",
      "items": {"type": "integer"}
    },
    "date": {
      "type": "string",
      "description": "ISO date YYYY-MM-DD. Defaults to today."
    }
  },
  "required": ["player_mlb_ids"]
}
```

**Returns:**
```json
{
  "date": "2026-07-03",
  "matchups": [
    {
      "hitter": {
        "mlb_id": 658668,
        "name": "Aaron Judge",
        "team": "NYY",
        "bat_side": "R",
        "season": {"avg": ".295", "hr": 21, "slg": ".588"}
      },
      "opponent_pitcher": {
        "mlb_id": 621111,
        "name": "Shane Baz",
        "team": "TB",
        "pitch_hand": "R",
        "season": {"era": "3.45", "whip": "1.18", "hr9": "1.2"}
      },
      "venue": "Tropicana Field",
      "game_pk": 748300
    },
    {
      "hitter": {"mlb_id": 999001, "name": "Some Player"},
      "no_game": true
    }
  ]
}
```

---

### `research_player_matchup`

Deep Exa.ai web research for a single hitter vs. pitcher matchup (used for default question 2).

**Description:** "Deep web research for a single hitter-vs-pitcher matchup: recent form, the pitcher's HR vulnerability vs the hitter's handedness, ballpark HR factor, and weather/forecast. Returns compact research snippets with source URLs for the model to synthesize into a likelihood assessment. Call once per hitter; calls run in parallel."

**Backing module:** `MlbFan.Mcp.Tools.ResearchPlayerMatchup`
**Backing function:** `MlbFan.Research.Matchup.research(args)`

**Fan-out behavior:** This tool is called once per hitter. Multiple calls emitted in the same assistant turn are executed concurrently by `ToolRouter` (max 8 concurrent). Each call internally fans out 4 Exa queries in parallel (`Task.async_stream`, max 4 concurrent), so worst-case concurrency is ~32 simultaneous Exa requests. Each Exa search returns up to 4 results, deduped to max 2 per domain, capped at 3 snippets per angle.

**Exa query angles:**
- A `recent_form`: `"{hitter} recent home runs form last 2 weeks {year}"`
- B `pitcher_hr_risk`: `"{pitcher} home runs allowed vs {LHB|RHB} HR/9 {year}"`
- C `park_factor`: `"{venue} home run park factor {year}"`
- D `weather`: `"{venue} weather forecast wind {date} game"`

**Input schema:**
```json
{
  "type": "object",
  "properties": {
    "hitter_name": {"type": "string"},
    "hitter_mlb_id": {"type": "integer"},
    "pitcher_name": {"type": "string"},
    "pitcher_mlb_id": {"type": "integer"},
    "venue": {"type": "string"},
    "date": {"type": "string", "description": "ISO date YYYY-MM-DD."}
  },
  "required": ["hitter_name", "pitcher_name"]
}
```

**Returns:**
```json
{
  "hitter": "Aaron Judge",
  "pitcher": "Shane Baz",
  "snippets": [
    {
      "angle": "recent_form",
      "title": "Aaron Judge Hits Two HRs ...",
      "url": "https://example.com/article",
      "text": "Judge homered twice on Tuesday ...",
      "published_date": "2026-07-01T00:00:00Z"
    }
  ]
}
```

---

## Prompts

Prompts are available via `prompts/list` and `prompts/get` on the MCP server. They return a single user message that can be injected as the user turn. The app's default buttons use inline user-turn text instead, but the MCP prompts are equivalent and available to external clients.

---

### `hrs_yesterday_with_streaks`

Parameterized version of default question 1.

**Arguments:**
| Argument | Type | Description |
|---|---|---|
| `date` | string (optional) | ISO date YYYY-MM-DD. Defaults to yesterday (America/New_York). |

**Rendered message:**
> "For {date}, list everyone who hit a home run and, for each of those players, their current home-run streak (consecutive team games with at least one HR) and hitting streak. Use get_homers_by_date then get_player_streaks. Present a clean table sorted by HR streak descending, then a short note on any multi-HR games that day."

**Backing module:** `MlbFan.Mcp.Prompts.HrsYesterdayWithStreaks`

---

### `matchup_odds_followup`

Parameterized version of default question 2.

**Arguments:**
| Argument | Type | Description |
|---|---|---|
| `player_mlb_ids` | list of integers (required) | The HR-hitter MLB ids from the prior answer. |
| `date` | string (optional) | ISO date YYYY-MM-DD. Defaults to today. |

**Rendered message:**
> "From the list of players who homered yesterday ({ids}), determine who is playing today and against which probable starting pitcher, then assess each hitter's chance of doing well today (especially multi-HR / back-to-back-HR potential) based on the pitcher's and hitter's stats plus deep research. Use get_matchups_for_players, then call research_player_matchup once per hitter. For each hitter give a 1–10 confidence score, the key supporting factors, and cite sources. Rank the list best-to-worst. Include the responsible-gambling note."

**Backing module:** `MlbFan.Mcp.Prompts.MatchupOddsFollowup`

---

## Connecting an External MCP Client

The server speaks the MCP Streamable HTTP transport. To connect Claude Desktop or another external client:

1. Point your client at `http://localhost:4000/mcp` (or the host/port where the app is running).
2. Send the `initialize` handshake with protocol version `2024-11-05` or later.
3. Call `tools/list` to enumerate all 9 tools, `prompts/list` for the 2 prompts.
4. Call `tools/call` or `prompts/get` as normal.

**Note:** The `/mcp` endpoint is unauthenticated. Only expose it on a trusted local network.
