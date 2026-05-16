#!/usr/bin/env bash
# Installs a local OTEL stack for Claude Code (Collector + Prometheus + Loki + Grafana)
# and patches ~/.claude/settings.json to export telemetry via OTLP/gRPC.
#
# What this script changes in ~/.claude/settings.json
# ---------------------------------------------------
# It merges (does not overwrite) the following keys into the top-level "env" object.
# A timestamped backup of the original file is written next to it before any edit.
#
#   CLAUDE_CODE_ENABLE_TELEMETRY=1       — master switch; without it nothing is emitted
#   OTEL_METRICS_EXPORTER=otlp           — push token/cost/session counters to the collector
#   OTEL_LOGS_EXPORTER=otlp              — push events (user_prompt, tool_result, …) to the collector
#   OTEL_EXPORTER_OTLP_PROTOCOL=grpc     — wire format for the OTLP exporter
#   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
#                                        — where the collector is listening (this stack)
#   OTEL_METRIC_EXPORT_INTERVAL=10000    — flush metrics every 10s (default is 60s)
#   OTEL_LOGS_EXPORT_INTERVAL=5000       — flush logs every 5s
#   OTEL_LOG_USER_PROMPTS=1              — include the prompt text in user_prompt events.
#                                          REQUIRED if you want the "Slash invocations" panel
#                                          (it regex-extracts /skill names from the prompt).
#                                          Set to 0 if you'd rather not have prompts stored.
#   OTEL_RESOURCE_ATTRIBUTES=service.name=claude-code,user.id=<you>
#                                        — tags every signal with these resource attrs
#
# Nothing else in settings.json is touched.
set -euo pipefail

TARGET_DIR="${1:-$(pwd)/claudescope}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
USER_ID="${USER_ID:-$(whoami)}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v jq     >/dev/null || { echo "jq not found (brew install jq)"; exit 1; }

echo "==> Creating tree at $TARGET_DIR"
mkdir -p "$TARGET_DIR/grafana/provisioning/datasources" \
         "$TARGET_DIR/grafana/provisioning/dashboards" \
         "$TARGET_DIR/grafana/dashboards" \
         "$TARGET_DIR/correlator"

cat > "$TARGET_DIR/docker-compose.yml" <<'YAML'
name: claudescope

services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.111.0
    container_name: claude-otel-collector
    command: ["--config=/etc/otel/config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel/config.yaml:ro
    ports:
      - "4317:4317"
      - "4318:4318"
      - "8889:8889"
    depends_on: [prometheus, loki]

  prometheus:
    image: prom/prometheus:v2.55.0
    container_name: claude-prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=60d"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports: ["9090:9090"]

  loki:
    image: grafana/loki:3.2.1
    container_name: claude-loki
    command: ["-config.file=/etc/loki/local-config.yaml"]
    ports: ["3100:3100"]
    volumes:
      - ./loki-config.yaml:/etc/loki/local-config.yaml:ro
      - loki-data:/loki

  grafana:
    image: grafana/grafana:11.3.0
    container_name: claude-grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    ports: ["3000:3000"]
    depends_on: [prometheus, loki]

  correlator:
    build: ./correlator
    container_name: claude-correlator
    environment:
      LOKI_URL: http://loki:3100
      WINDOW_HOURS: "24"
      INTERVAL_SECONDS: "30"
    depends_on: [loki]

volumes:
  prometheus-data:
  loki-data:
  grafana-data:
YAML

cat > "$TARGET_DIR/otel-collector-config.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024
  attributes/loki_labels:
    actions:
      - key: loki.attribute.labels
        value: event.name,tool_name,model,user.id,session.id
        action: insert

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion: { enabled: true }
  otlphttp/loki:
    endpoint: http://loki:3100/otlp

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [attributes/loki_labels, batch]
      exporters: [otlphttp/loki]
YAML

cat > "$TARGET_DIR/prometheus.yml" <<'YAML'
global:
  scrape_interval: 10s
  evaluation_interval: 10s
scrape_configs:
  - job_name: otel-collector
    static_configs:
      - targets: ["otel-collector:8889"]
  - job_name: correlator
    static_configs:
      - targets: ["correlator:9100"]
YAML

cat > "$TARGET_DIR/correlator/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-slim
RUN pip install --no-cache-dir requests==2.32.3 prometheus_client==0.21.0
COPY correlator.py /correlator.py
EXPOSE 9100
CMD ["python", "-u", "/correlator.py"]
DOCKERFILE

cat > "$TARGET_DIR/correlator/correlator.py" <<'PY'
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
PY

cat > "$TARGET_DIR/loki-config.yaml" <<'YAML'
auth_enabled: false

server:
  http_listen_port: 3100

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

compactor:
  working_directory: /loki/compactor
  delete_request_store: filesystem
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

limits_config:
  retention_period: 60d
  allow_structured_metadata: true
  volume_enabled: true

ruler:
  alertmanager_url: http://localhost:9093
YAML

cat > "$TARGET_DIR/grafana/provisioning/datasources/datasources.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
YAML

cat > "$TARGET_DIR/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1
providers:
  - name: claude-code
    orgId: 1
    folder: Claude Code
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
YAML

cat > "$TARGET_DIR/grafana/dashboards/claude-overview.json" <<'JSON'
{
  "title": "Claude Code — Overview",
  "uid": "claude-overview",
  "schemaVersion": 39,
  "version": 5,
  "refresh": "10s",
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    { "id": 1, "type": "stat", "title": "Total tokens (input + output)",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "sum(claude_code_token_usage_tokens_total)", "refId": "A" } ] },
    { "id": 2, "type": "stat", "title": "Total cost (USD)",
      "gridPos": { "x": 6, "y": 0, "w": 6, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "sum(claude_code_cost_usage_USD_total)", "refId": "A" } ],
      "fieldConfig": { "defaults": { "unit": "currencyUSD" } } },
    { "id": 3, "type": "timeseries", "title": "Tokens by type",
      "gridPos": { "x": 0, "y": 4, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "sum by (type) (rate(claude_code_token_usage_tokens_total[5m]))", "legendFormat": "{{type}}", "refId": "A" } ] },
    { "id": 4, "type": "timeseries", "title": "Tokens by model",
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 8 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "sum by (model) (rate(claude_code_token_usage_tokens_total[5m]))", "legendFormat": "{{model}}", "refId": "A" } ] },
    { "id": 5, "type": "bargauge", "title": "Tool usage (count by tool)",
      "gridPos": { "x": 0, "y": 12, "w": 12, "h": 8 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "sum by (tool_name) (count_over_time({service_name=\"claude-code\"} | event_name=\"tool_result\" [$__range]))", "legendFormat": "{{tool_name}}", "refId": "A" } ],
      "options": { "reduceOptions": { "calc": "lastNotNull", "fields": "", "values": false }, "orientation": "horizontal", "displayMode": "gradient" } },
    { "id": 6, "type": "logs", "title": "Recent events",
      "gridPos": { "x": 12, "y": 12, "w": 12, "h": 8 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "{service_name=\"claude-code\"}", "refId": "A" } ] },
    { "id": 7, "type": "bargauge", "title": "Slash invocations (skills + commands, from user_prompt)",
      "description": "Claude Code anonymizes user-defined skill names as 'custom_skill'. This regex-extracts the real name from the leading slash in user prompts (requires OTEL_LOG_USER_PROMPTS=1).",
      "gridPos": { "x": 0, "y": 20, "w": 16, "h": 8 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "sum by (skill) (count_over_time({service_name=\"claude-code\"} | event_name=\"user_prompt\" | prompt =~ `^/.*` | line_format \"{{.prompt}}\" | regexp `^/(?P<skill>[a-zA-Z][a-zA-Z0-9_-]*)` [$__range]))", "legendFormat": "{{skill}}", "refId": "A" } ],
      "options": { "reduceOptions": { "calc": "lastNotNull", "fields": "", "values": false }, "orientation": "horizontal", "displayMode": "gradient" } },
    { "id": 13, "type": "stat", "title": "Skill activations by source",
      "gridPos": { "x": 16, "y": 20, "w": 8, "h": 8 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "sum by (skill_source) (count_over_time({service_name=\"claude-code\"} | event_name=\"skill_activated\" [$__range]))", "legendFormat": "{{skill_source}}", "refId": "A", "queryType": "instant" } ] },
    { "id": 8, "type": "stat", "title": "Avg tokens per session",
      "gridPos": { "x": 0, "y": 28, "w": 8, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "avg(sum by (session_id) (claude_code_token_usage_tokens_total))", "refId": "A" } ],
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 0 } } },
    { "id": 9, "type": "bargauge", "title": "Avg tokens per session, by type",
      "gridPos": { "x": 8, "y": 28, "w": 8, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "avg by (type) (sum by (session_id, type) (claude_code_token_usage_tokens_total))", "legendFormat": "{{type}}", "refId": "A" } ] },
    { "id": 10, "type": "stat", "title": "Sessions seen",
      "gridPos": { "x": 16, "y": 28, "w": 8, "h": 4 },
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "targets": [ { "expr": "count(count by (session_id) (claude_code_token_usage_tokens_total))", "refId": "A" } ] },
    { "id": 11, "type": "bargauge", "title": "Top tools by output bytes (proxy for token cost)",
      "gridPos": { "x": 0, "y": 32, "w": 12, "h": 10 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "topk(10, sum by (tool_name) (sum_over_time({service_name=\"claude-code\"} | event_name=\"tool_result\" | unwrap tool_result_size_bytes [$__range])))", "legendFormat": "{{tool_name}}", "refId": "A" } ],
      "fieldConfig": { "defaults": { "unit": "bytes" } },
      "options": { "reduceOptions": { "calc": "lastNotNull", "fields": "", "values": false }, "orientation": "horizontal", "displayMode": "gradient" } },
    { "id": 12, "type": "bargauge", "title": "MCP tools by output bytes",
      "gridPos": { "x": 12, "y": 32, "w": 12, "h": 10 },
      "datasource": { "type": "loki", "uid": "Loki" },
      "targets": [ { "expr": "sum by (tool_name) (sum_over_time({service_name=\"claude-code\"} | event_name=\"tool_result\" | tool_name=~\"mcp__.+\" | unwrap tool_result_size_bytes [$__range]))", "legendFormat": "{{tool_name}}", "refId": "A" } ],
      "fieldConfig": { "defaults": { "unit": "bytes", "noValue": "No MCP usage in range" } },
      "options": { "reduceOptions": { "calc": "lastNotNull", "fields": "", "values": false }, "orientation": "horizontal", "displayMode": "gradient" } }
  ]
}
JSON

echo "==> Patching $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

ENV_PATCH=$(jq -n --arg uid "$USER_ID" '{
  CLAUDE_CODE_ENABLE_TELEMETRY: "1",
  OTEL_METRICS_EXPORTER: "otlp",
  OTEL_LOGS_EXPORTER: "otlp",
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc",
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:4317",
  OTEL_METRIC_EXPORT_INTERVAL: "10000",
  OTEL_LOGS_EXPORT_INTERVAL: "5000",
  OTEL_LOG_USER_PROMPTS: "1",
  OTEL_RESOURCE_ATTRIBUTES: ("service.name=claude-code,user.id=" + $uid)
}')
tmp=$(mktemp)
jq --argjson p "$ENV_PATCH" '.env = ((.env // {}) + $p)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "==> Starting the stack"
( cd "$TARGET_DIR" && docker compose up -d )

echo "==> Waiting 10s for services to be ready…"
sleep 10

echo "==> Health checks"
curl -sf http://localhost:9090/-/ready  >/dev/null && echo "  prometheus: OK" || echo "  prometheus: FAIL"
curl -sf http://localhost:3100/ready    >/dev/null && echo "  loki:       OK" || echo "  loki:       FAIL"
curl -sf http://localhost:3000/api/health >/dev/null && echo "  grafana:    OK" || echo "  grafana:    FAIL"

cat <<EOF

==> Done.
  Grafana:    http://localhost:3000  (admin/admin)
  Prometheus: http://localhost:9090
  Loki:       http://localhost:3100
  OTLP gRPC:  localhost:4317

Restart Claude Code so it reloads the env vars from $SETTINGS.
Settings backup saved as $SETTINGS.bak.*
EOF
