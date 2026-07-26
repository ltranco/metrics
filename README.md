# metrics

A "my life" metrics stack. Push arbitrary time series from anywhere (starting
with HealthKit via iOS Shortcuts), store them forever on a Linode, and graph
them in Grafana Cloud.

## Architecture

```
iOS Shortcut ──POST /ingest──▶ nginx ──▶ Go shim ──▶ VictoriaMetrics
                              (TLS)      (bearer)     (100y retention)
                                                            ▲
Grafana Cloud ──GET /api/v1/query*──▶ nginx ────────────────┘
                                     (basic auth, read-only)
```

Grafana Cloud is used as the **UI only** — its free tier's 14-day retention
applies to *their* hosted storage, which we don't use. History lives on our
disk and is unbounded.

Footprint on the Linode: ~50MB disk, ~70MB RAM.

## Ingest format

`POST /ingest` with `Authorization: Bearer $INGEST_TOKEN`:

```json
{
  "step":   { "2026-07-24": 8412, "2026-07-25": 10233 },
  "weight": { "2026-07-25": 71.2 }
}
```

Becomes `health_step{src="ios"}` and `health_weight{src="ios"}`
(VictoriaMetrics joins measurement + field with `_`).

Timestamp keys accept `YYYY-MM-DD`, RFC3339, or epoch seconds/millis. Bare
dates are interpreted in `LOCAL_TZ`.

Adding a new metric means adding a key to the JSON — nothing to configure.

**Post a rolling 7-day window, not just today.** `-dedup.minScrapeInterval=1ms`
collapses samples that share a timestamp and label set, so re-sending is free
and idempotent — a missed automation self-heals on the next run instead of
leaving a permanent hole.

## Local development

```bash
docker build -t metrics-shim:test ./shim
mkdir -p /tmp/mtest && cp deploy/docker-compose.prod.yml /tmp/mtest/docker-compose.yml
echo 'INGEST_TOKEN=testtoken123' > /tmp/mtest/.env
cd /tmp/mtest && DOCKER_IMAGE=metrics-shim:test docker compose up -d

curl -s -X POST localhost:8081/ingest -H 'Authorization: Bearer testtoken123' \
  -d '{"step":{"2026-07-25":6001},"weight":{"2026-07-25":71.2}}'

curl -s -G localhost:8428/api/v1/export --data-urlencode 'match[]={__name__=~"health.*"}' \
  --data-urlencode 'start=2026-07-01T00:00:00Z' --data-urlencode 'end=2026-08-01T00:00:00Z'
```

Note `/api/v1/label/__name__/values` defaults to the last 24h — pass explicit
`start`/`end` when inspecting backdated test data.

## Deploy

Push to `main`. CI builds `ghcr.io/ltranco/metrics` from `shim/`, SSHes to the
Linode, and runs `deploy/deploy.sh`.

### Required GitHub secrets

| Secret | Value |
| --- | --- |
| `LINODE_HOST` | Linode IP |
| `LINODE_USER` | SSH user |
| `SSH_PRIVATE_KEY` | Private key for that user |

(`GITHUB_TOKEN` is provided automatically.)

### One-time server setup

Secrets are placed by hand and never committed:

```bash
sudo mkdir -p /opt/metrics
printf 'INGEST_TOKEN=%s\n' "$(openssl rand -hex 24)" | sudo tee /opt/metrics/.env
sudo chmod 600 /opt/metrics/.env

sudo htpasswd -bc /etc/nginx/.htpasswd-metrics grafana '<password>'
```

Also add a DNS A record for `metrics.ltran.co`. The first deploy issues the
cert via certbot automatically.

## Grafana Cloud datasource

Type **Prometheus**, URL `https://metrics.ltran.co`, Basic auth with the
htpasswd credentials above.
