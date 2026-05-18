#!/usr/bin/env bash
# Installs the claudescope OTEL stack and patches ~/.claude/settings.json so
# Claude Code starts pushing telemetry to it.
#
# Run from a checkout of https://github.com/halan/claudescope:
#
#   git clone https://github.com/halan/claudescope.git
#   cd claudescope
#   ./install.sh                # installs in-place
#   ./install.sh /opt/somewhere # installs into a separate directory (copies the tree)
#
# What this script changes in ~/.claude/settings.json
# ---------------------------------------------------
# It merges (does not overwrite) the following keys into the top-level "env"
# object. A timestamped backup of the original file is written next to it
# before any edit.
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
#
# NOT set: OTEL_RESOURCE_ATTRIBUTES.
#   settings.json env vars override the shell environment at startup, so if we
#   set this here it would clobber the optional shell wrapper that adds
#   project=<repo>. Left unset so the wrapper (or OTEL default) wins.
#
# Nothing else in settings.json is touched.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$SOURCE_DIR}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v jq     >/dev/null || { echo "jq not found (brew install jq)"; exit 1; }

# Required source files / dirs — these are the source of truth.
REQUIRED=(
  docker-compose.yml
  otel-collector-config.yaml
  prometheus.yml
  loki-config.yaml
  grafana
  correlator
)
for f in "${REQUIRED[@]}"; do
  if [ ! -e "$SOURCE_DIR/$f" ]; then
    echo "error: $f not found next to install.sh"
    echo "       run install.sh from a checkout of github.com/halan/claudescope:"
    echo "         git clone https://github.com/halan/claudescope.git"
    echo "         cd claudescope && ./install.sh"
    exit 1
  fi
done

if [ "$TARGET_DIR" != "$SOURCE_DIR" ]; then
  echo "==> Copying stack to $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  for f in "${REQUIRED[@]}"; do
    cp -R "$SOURCE_DIR/$f" "$TARGET_DIR/"
  done
fi

echo "==> Patching $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

ENV_PATCH=$(jq -n '{
  CLAUDE_CODE_ENABLE_TELEMETRY: "1",
  OTEL_METRICS_EXPORTER: "otlp",
  OTEL_LOGS_EXPORTER: "otlp",
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc",
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:4317",
  OTEL_METRIC_EXPORT_INTERVAL: "10000",
  OTEL_LOGS_EXPORT_INTERVAL: "5000",
  OTEL_LOG_USER_PROMPTS: "1"
}')
tmp=$(mktemp)
jq --argjson p "$ENV_PATCH" '.env = ((.env // {}) + $p)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "==> Starting the stack"
( cd "$TARGET_DIR" && docker compose up -d --build )

echo "==> Waiting 10s for services to be ready…"
sleep 10

echo "==> Health checks"
curl -sf http://localhost:9090/-/ready    >/dev/null && echo "  prometheus: OK" || echo "  prometheus: FAIL"
curl -sf http://localhost:3100/ready      >/dev/null && echo "  loki:       OK" || echo "  loki:       FAIL"
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
