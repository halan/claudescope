# Roadmap

A logical, dependency-aware path for evolving claudescope. Items grouped into
phases — finish a phase (or get its key items done) before jumping ahead, since
later items reuse patterns established earlier.

Effort: **S** = under 1h, **M** = 1–3h, **L** = half-day or more.

Every item lists what it adds and how to know it's done.

---

## Phase 1 — Polish the Overview dashboard

Sharpens what's already there. No new services, no new metrics. Pure dashboard
edits — fast feedback, low risk.

### 1.1 Sparklines on all headline KPIs (S)
**What.** Add a `graph` mode to the Total cost, Avg cost/session, and Cache hit ratio stats so they show a mini-trend like Total tokens already does.
**Done when.** All four headline tiles show a small sparkline at the bottom.

### 1.2 Threshold colors on Cost rate (S)
**What.** Paint the Cost rate timeseries yellow above $0.005/sec, red above $0.02/sec (tune to your usage).
**Done when.** The chart visually flags spending spikes without you having to read the number.

### 1.3 Annotations for api_error events (S)
**What.** Add a Loki-backed annotation query: `{service_name="claude-code"} | event_name="api_error"`. Shows as red vertical lines on every timeseries panel.
**Done when.** Errors appear as red dots/lines correlating with cost or latency dips.

### 1.4 `$session_id` template variable (M)
**What.** Add a Grafana variable populated from `label_values(claude_code_token_usage_tokens_total, session_id)`. Wire it into all PromQL queries via `{session_id=~"$session_id"}`. Default to "All".
**Done when.** A dropdown in the dashboard header lets you slice every panel by session.
**Why this is in Phase 1.** It's a prerequisite for the Session Explorer (3.1) and a multiplier for the existing dashboard.

### 1.5 Tooltip with skill_source on Slash invocations (S)
**What.** Add a second Loki query that joins `skill_activated.skill_source` by session_id, surface as a tooltip override on the Slash panel.
**Done when.** Hovering a skill bar shows "userSettings / builtin / plugin".

---

## Phase 2 — Secondary dashboards

Each lives as a separate file under `grafana/dashboards/`. Reuses the same data
sources, no new services. Dashboard provisioning picks them up automatically.

### 2.1 Performance / Latency (M)
**What.** New dashboard `claude-performance.json` answering "is the model slow?".
- p50 / p95 / p99 of `api_request_duration_ms` (from `api_request` events, `unwrap duration_ms`).
- Latency by model (Haiku vs Opus side-by-side).
- Top 10 slowest individual `api_request` calls (table).
- Tool execution time histogram (from `tool_result.duration_ms`).
**Done when.** You can answer "did Opus get slower in the last hour?" at a glance.

### 2.2 Errors / Reliability (M)
**What.** New dashboard `claude-errors.json`.
- `api_error` rate over time (Loki count).
- Error breakdown by status / type (parse the message field).
- Tool failures: `{event_name="tool_result"} | success="false"` count by tool.
- Permission rejects: `{event_name="tool_decision"} | decision_type="reject"`.
**Done when.** Errors and rejections that are silent today become visible.

### 2.3 Session Explorer (L)
**What.** Dashboard `claude-session.json` with a required `$session_id` variable.
- Cumulative cost line (single session).
- Tool calls in chronological order (table).
- Slash invocations (timeline).
- Per-turn `api_request` duration (bars).
- Errors as annotations.
**Done when.** Pasting a session_id from the Overview lets you reconstruct what happened in that session.
**Depends on.** 1.4 (template variable pattern reused).

### 2.4 Productivity (S)
**What.** Dashboard `claude-productivity.json` using metrics that exist but no panel reads:
- `claude_code_lines_of_code_count_total` over time.
- `claude_code_commit_count_total` per project.
- `claude_code_pull_request_count_total` per project.
- Cost-per-line-of-code = `cost_total / lines_of_code_total`.
- Cost-per-commit.
**Done when.** You can compare "this month I shipped 1200 LOC for $X" across projects.

---

## Phase 3 — Correlator extensions

Existing sidecar already attributes tokens/cost per skill. These items extend
the same attribution model to new dimensions. Each requires a small change to
`correlator/correlator.py` plus a new metric exposed.

### 3.1 Per-skill latency (M)
**What.** While correlating, also accumulate `duration_ms` from each `api_request`. Expose `claude_code_skill_duration_ms{skill}` (sum) and emit a histogram if cheap.
**Panel.** Add to "by skill" row of Overview. Or to Performance dashboard.
**Done when.** "Tokens by skill" has a sibling "Avg seconds per skill turn" panel.

### 3.2 Per-skill error rate (M)
**What.** Track `api_error` events per skill in the same correlator pass. Expose `claude_code_skill_errors_total{skill}` and a derived ratio `errors / turns`.
**Panel.** Add to Errors dashboard, broken down by skill.
**Done when.** You can tell "/judge-knowledge fails 8% of the time, /init never fails".

### 3.3 Skill ROI (cost per invocation) (S)
**What.** Already derivable from existing metrics: `claude_code_skill_cost_usd / claude_code_skill_invocations`. Add the invocation counter to the correlator (count user_prompt with leading `/<skill>` per skill).
**Panel.** New panel "Avg cost per skill invocation" in Overview.
**Done when.** "/init costs $1.20 per use, /btw costs $0.04" is visible.

### 3.4 Per-tool latency attribution (L)
**What.** Bigger lift. Correlator joins `tool_result` (which has `duration_ms` and `tool_name`) and aggregates by tool. Exposes `claude_code_tool_duration_ms{tool_name}`.
**Panel.** Performance dashboard.
**Done when.** "Bash p95 = 2s, Read p95 = 50ms" answerable.
**Note.** Could also be done with pure LogQL if Loki's perf is enough — try LogQL first, fall back to correlator only if necessary.

---

## Phase 4 — Alerting

Requires Grafana Alerting + a notification channel (start with desktop
notification or a webhook to your own service; Slack/Discord later).

### 4.1 Daily cost cap (S)
**Rule.** `sum(increase(claude_code_cost_usage_USD_total[24h])) > $X`.
**Default threshold.** $10/day — adjust to taste.

### 4.2 Expensive single session (S)
**Rule.** `max(sum by (session_id) (claude_code_cost_usage_USD_total)) > $Y` over the last hour.

### 4.3 Error spike (S)
**Rule.** Loki: `rate({service_name="claude-code"} | event_name="api_error" [10m]) > 0.1` (more than 6 errors per minute over 10 minutes).
**Depends on.** 2.2 (Errors dashboard) — alert links to it for context.

### 4.4 Per-skill cost runaway (M)
**Rule.** `rate(claude_code_skill_cost_usd[1h]) > $Z`.
**Depends on.** 3.3 — useful when paired with skill ROI.

---

## Out of scope for now (but worth a note)

- **Auto-compaction visibility.** Still blocked on Claude Code emitting an event for it. Workaround: a `PreCompact` hook in `~/.claude/settings.json` that writes a marker line we can ingest.
- **True per-tool token cost from metrics.** Same root cause as before — `claude_code_cost_usage_USD_total` doesn't carry `tool_name`. Byte-size proxy is in place; correlator extension (3.4) will narrow this.
- **Multi-machine aggregation.** Current stack assumes one user, one machine. Adding `host_arch` / `os_type` filters would let teams share a stack.

---

## How to use this file

- Pick the next item in the lowest-numbered unfinished phase.
- Items inside a phase are roughly independent — feel free to reorder by interest.
- When done, delete the item or move it to a "Shipped" section at the bottom.
