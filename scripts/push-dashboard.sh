#!/usr/bin/env bash
# Push a dashboard JSON to Grafana via the HTTP API.
#
#   ./scripts/push-dashboard.sh [path/to/dashboard.json]
#
# Token is read from $GRAFANA_TOKEN, else from .grafana-token (gitignored).
# Create one at: Administration -> Users and access -> Service accounts
#   -> Add service account (role: Editor) -> Add service account token
set -euo pipefail

DASH="${1:-dashboards/proto.json}"
GRAFANA_URL="${GRAFANA_URL:-https://ltranco.grafana.net}"

if [ -z "${GRAFANA_TOKEN:-}" ]; then
    TOKEN_FILE="${GRAFANA_TOKEN_FILE:-.grafana-token}"
    if [ ! -f "$TOKEN_FILE" ]; then
        echo "ERROR: no GRAFANA_TOKEN set and no $TOKEN_FILE found." >&2
        echo "  echo 'glsa_...' > $TOKEN_FILE && chmod 600 $TOKEN_FILE" >&2
        exit 1
    fi
    GRAFANA_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
fi

[ -f "$DASH" ] || { echo "ERROR: $DASH not found" >&2; exit 1; }

# Wrap the dashboard in the API envelope. Strip any id so uid+overwrite
# decides the target rather than a stale numeric id.
body=$(python3 - "$DASH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("id", None)
print(json.dumps({"dashboard": d, "overwrite": True, "message": "pushed from repo"}))
PY
)

resp=$(curl -sS -w '\n%{http_code}' -X POST "$GRAFANA_URL/api/dashboards/db" \
    -H "Authorization: Bearer $GRAFANA_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary "$body")

code=$(printf '%s' "$resp" | tail -1)
payload=$(printf '%s' "$resp" | sed '$d')

if [ "$code" != "200" ]; then
    echo "FAILED (HTTP $code): $payload" >&2
    exit 1
fi

ver=$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
url=$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
echo "OK - dashboard version $ver"
echo "     $GRAFANA_URL$url"
