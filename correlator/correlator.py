"""
Claude Code skill→cost correlator.

Polls Loki on an interval, walks each session's timeline, and attributes the
tokens/cost of each api_request to whatever /<skill> the user most recently
invoked in that session. Anything before the first slash invocation, or
between sessions where the user never typed a slash, is bucketed as __chat.

Exposes Prometheus metrics on :9100:
  claude_code_skill_tokens{skill, type}  — counts in the last WINDOW_HOURS
  claude_code_skill_cost_usd{skill}      — USD in the last WINDOW_HOURS
  claude_code_skill_turns{skill}         — number of api_request turns

Gauges, not counters — each scrape reflects the current window snapshot.
"""
import os
import re
import time
from collections import defaultdict

import requests
from prometheus_client import Gauge, start_http_server

LOKI = os.environ.get("LOKI_URL", "http://loki:3100")
WINDOW_HOURS = int(os.environ.get("WINDOW_HOURS", "24"))
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "30"))
PORT = int(os.environ.get("PORT", "9100"))
CHAT_BUCKET = "__chat"
QUERY_LIMIT = 5000

SLASH_RE = re.compile(r"^/([a-zA-Z][a-zA-Z0-9_-]*)")

tokens_g = Gauge(
    "claude_code_skill_tokens",
    "Tokens attributed to a slash-invoked skill (correlator window)",
    ["skill", "type"],
)
cost_g = Gauge(
    "claude_code_skill_cost_usd",
    "USD attributed to a slash-invoked skill (correlator window)",
    ["skill"],
)
turns_g = Gauge(
    "claude_code_skill_turns",
    "api_request turns attributed to a slash-invoked skill (correlator window)",
    ["skill"],
)


def fetch_events():
    end = int(time.time() * 1e9)
    start = end - WINDOW_HOURS * 3600 * 10**9
    params = {
        "query": '{service_name="claude-code"} | event_name=~"user_prompt|api_request"',
        "limit": QUERY_LIMIT,
        "start": start,
        "end": end,
        "direction": "forward",
    }
    r = requests.get(f"{LOKI}/loki/api/v1/query_range", params=params, timeout=30)
    r.raise_for_status()
    out = []
    for stream in r.json()["data"]["result"]:
        meta = stream["stream"]
        for ts, _line in stream["values"]:
            out.append({"ts": int(ts), **meta})
    return out


def _f(d, key):
    try:
        return float(d.get(key, 0) or 0)
    except (TypeError, ValueError):
        return 0.0


def correlate(events):
    by_session = defaultdict(list)
    for e in events:
        sid = e.get("session_id")
        if sid:
            by_session[sid].append(e)

    tokens = defaultdict(lambda: defaultdict(float))
    cost = defaultdict(float)
    turns = defaultdict(int)

    for evs in by_session.values():
        evs.sort(key=lambda e: int(e.get("event_sequence", 0) or 0))
        current = CHAT_BUCKET
        for e in evs:
            name = e.get("event_name")
            if name == "user_prompt":
                m = SLASH_RE.match(e.get("prompt", "") or "")
                current = m.group(1) if m else CHAT_BUCKET
            elif name == "api_request":
                turns[current] += 1
                tokens[current]["input"] += _f(e, "input_tokens")
                tokens[current]["output"] += _f(e, "output_tokens")
                tokens[current]["cacheRead"] += _f(e, "cache_read_tokens")
                tokens[current]["cacheCreation"] += _f(e, "cache_creation_tokens")
                cost[current] += _f(e, "cost_usd")

    return tokens, cost, turns


def publish(tokens, cost, turns):
    tokens_g.clear()
    cost_g.clear()
    turns_g.clear()
    for skill, type_map in tokens.items():
        for t, v in type_map.items():
            tokens_g.labels(skill=skill, type=t).set(v)
    for skill, v in cost.items():
        cost_g.labels(skill=skill).set(v)
    for skill, v in turns.items():
        turns_g.labels(skill=skill).set(v)


def main():
    start_http_server(PORT)
    print(f"correlator listening on :{PORT}, polling {LOKI} every {INTERVAL}s, window={WINDOW_HOURS}h", flush=True)
    while True:
        try:
            events = fetch_events()
            tokens, cost, turns = correlate(events)
            publish(tokens, cost, turns)
            total_turns = sum(turns.values())
            print(f"updated: {total_turns} turns across {len(turns)} skills — {list(turns.keys())}", flush=True)
        except Exception as exc:
            print(f"error: {exc}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
