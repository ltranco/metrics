# CLAUDE.md

Guidance for Claude Code working in this repo. Read this before touching anything.

## What this is

A personal "my life" metrics stack. An iOS Shortcut posts HealthKit data to a
Go shim on a Linode, which writes it to VictoriaMetrics. Grafana Cloud renders
it. Adding a new metric requires no code — just a new key in the JSON payload.

```
iOS Shortcut ──POST /ingest──▶ nginx ──▶ Go shim ──▶ VictoriaMetrics
                               (TLS)     (bearer)     (100y retention)
                                                            ▲
Grafana Cloud ──GET /api/v1/query*──▶ nginx ────────────────┘
                                     (basic auth, read-only)
```

## Identity — read this first

**Never use the `gh` CLI in this repo.** It is authenticated as `ctxlong`
(the user's work/mem0 account). This is a personal repo under `ltranco`.

Plain `git` over SSH is correct and already pinned locally:

```
user.name       Long Tran
user.email      ltran.co8@gmail.com
core.sshCommand ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes
```

`~/.ssh/id_ed25519` → **ltranco**. `~/.ssh/id_ed25519_mem0` → ctxlong. Verify
with `ssh -T -o IdentitiesOnly=yes -i <key> git@github.com`.

For repo secrets or anything else needing the GitHub API, ask the user to do it
in the web UI.

## Layout

| Path | |
| --- | --- |
| `shim/main.go` | ingest service — nested JSON → Influx line protocol |
| `shim/Dockerfile` | multi-stage → `scratch`, 6.75MB image, ~5MiB resident |
| `deploy/deploy.sh` | runs on the box: nginx, certbot, compose, health gate |
| `deploy/docker-compose.prod.yml` | VictoriaMetrics + shim |
| `deploy/nginx.conf` | `/ingest` + read-API allowlist, everything else 404 |
| `dashboards/proto.json` | the dashboard, source of truth |
| `scripts/push-dashboard.sh` | pushes that JSON to Grafana over the API |
| `.github/workflows/` | `ci.yml` (go vet/build), `deploy.yml` (GHCR → SSH) |

## Infrastructure

- **Linode** `173.255.246.10`, SSH alias `linode` (root). Also runs the
  unrelated `gold` app — **this box is shared**.
- **1GB Nanode. RAM is the binding constraint, not disk.** ~400Mi available,
  15G disk free. The whole metrics stack is ~20MiB resident; keep it that way.
  This is why the shim is Go on `scratch` and not Python (~60-90MiB), and why
  Grafana is not self-hosted here.
- Server paths: `/opt/metrics` (compose + `.env`), `/opt/metrics-repo` (CI
  checkout). Containers: `metrics-vm`, `metrics-shim`.
- Host nginx terminates TLS for `metrics.ltran.co` (certbot). `ltran.co` is on
  **Cloudflare**, proxied — DNS records go in Cloudflare, not a registrar.
- Swap is `/dev/sdb` (Linode's 512M disk) **plus** a 2G `/swapfile`;
  `vm.swappiness=10`; journald capped at 200M.

## Credentials — where each one lives

| Secret | Location | Notes |
| --- | --- | --- |
| `INGEST_TOKEN` | `/opt/metrics/.env` on the box | bearer token for `POST /ingest` |
| read-API basic auth | `/etc/nginx/.htpasswd-metrics` | user `grafana` |
| CI deploy key | `~/.ssh/metrics_deploy` (local) | public half in `/home/deploy/.ssh/authorized_keys` |
| Grafana API token | `.grafana-token` in repo root | **gitignored**, service account `dashboard-sync` |

GitHub Actions secrets: `LINODE_HOST=173.255.246.10`, `LINODE_USER=deploy`,
`SSH_PRIVATE_KEY` = contents of `~/.ssh/metrics_deploy`.

Grafana Cloud: stack `ltranco.grafana.net`, Prometheus datasource uid
`dft9acuz7p05cd`, dashboard uid **`proto`** (not `my-life` — see below).

Read the ingest token with `ssh linode 'cat /opt/metrics/.env'`. To rotate:
write a new value, `cd /opt/metrics && docker compose up -d`, update the
Shortcut.

## Workflows

**Code:** push to `main`. CI builds `ghcr.io/ltranco/metrics` from `shim/`,
SSHes in as `deploy`, runs `deploy/deploy.sh`.

**Dashboard:** edit `dashboards/proto.json`, then

```bash
./scripts/push-dashboard.sh
```

That POSTs to `/api/dashboards/db` with `overwrite: true` and prints the new
version. Do **not** tell the user to copy-paste into the import screen.

**Verify a change landed** by reading it back — the token can read `proto`:

```bash
TOKEN=$(tr -d '\r\n' < .grafana-token)
curl -sS -H "Authorization: Bearer $TOKEN" \
  https://ltranco.grafana.net/api/dashboards/uid/proto
```

## Decisions, and why

**VictoriaMetrics, not Prometheus.** Prometheus is pull-based, Pushgateway
discards timestamps (fatal for backdated HealthKit data), and its 5-minute
staleness turns sparse daily metrics into isolated dots. VM takes pushed writes
with real timestamps and still speaks PromQL.

**Grafana Cloud is the UI only.** Its free-tier 14-day retention applies to
*their* hosted storage, which is unused. History lives on the Linode at
`-retentionPeriod=100y`. Never wire this up to Grafana's hosted metrics.

**The dashboard uid is `proto`.** The user created it by hand before the API
workflow existed. A push targeting a different uid silently creates a duplicate
rather than erroring — that happened once. The file is named to match the uid so
they can't drift. Keep the title `proto`; the user asked for it explicitly.

**Post a rolling window from the Shortcut, not just today.** Re-sends are cheap
and a missed automation self-heals.

## Traps

These all cost real debugging time. Do not rediscover them.

1. **Always query `last_over_time(metric[<step>])`, never a bare selector.**
   `-search.maxStalenessInterval=720h` means a bare selector carries the last
   value forward for 30 days, so a day with no sync silently inherits the
   previous day's number.

2. **Use `interval: 1h` and `maxDataPoints: 10000` on daily-data panels.**
   `interval: 1d` makes Grafana evaluate on **UTC** midnights. The user is
   UTC−7, so the first eval window covering a sample stamped at local midnight
   is the *next* UTC midnight — 17:00 local. Today is invisible for 17 hours a
   day. Costs nothing: VM only emits points where the window holds a sample, so
   30 days returns ~30 points, not 720.

3. **`-dedup.minScrapeInterval=1ms` keeps the BIGGEST value on a timestamp tie,
   not the newest.** A re-post cannot correct a value downward. Removing the
   flag does not give last-write-wins either (tested: 11004 → 6151 → 999 all
   returned 6151). Corrections require
   `POST /api/v1/admin/tsdb/delete_series` then re-posting.

4. **`-search.maxStalenessInterval` is a Go duration flag** — `30d` fails to
   parse, use `720h`.

5. **`/api/v1/label/__name__/values` defaults to the last 24h.** Pass explicit
   `start`/`end` when inspecting backdated data or it looks empty.

6. **iOS Shortcuts sends numbers as quoted strings** (`"6151"`) — handled by
   `flexFloat` in the shim — **and sends `0` when HealthKit has no sample.**
   Weight panels filter with `> 0`; nulls never reach storage.

7. **The `deploy` user's sudoers allowlist has no `mkdir`**, and `/opt` is
   root-owned. `/opt/metrics` and `/opt/metrics-repo` are pre-created and
   chowned by hand. Don't add `sudo mkdir` to `deploy.sh`.

8. **gold's `deploy.sh` runs `docker system prune -af --filter until=72h`.**
   Metrics images survive only while the containers are running.

9. **Grafana panel time overrides are ignored when the dashboard range is
   absolute.** The pinned week row silently follows the picker if the user
   zooms to a fixed window.

10. **Business Charts v7 compiles the script as `new Function("context", …)`.**
    Bare `data`/`theme` are not in scope. Use `context.panel.data` and
    `context.grafana.theme`. Shape:
    `{grafana:{theme, replaceVariables, …}, panel:{data, chart}, echarts, ecStat}`.

11. **Grafana's `gradientMode: opacity` only ramps a flat fill's alpha.** It
    reads as almost nothing. Real multi-stop gradients need ECharts.

12. **`tim012432-calendarheatmap-panel` cannot do threshold colours.** Its
    `module.js` has zero references to `thresholds`/`fieldConfig`/`color.mode`;
    `colorScheme` is a single-hue ramp. It's installed but unused.

## Dashboard

Two rows. **This week** is pinned via `timeFrom: "now/w"` and ignores the
picker; **History** follows it.

| Panel | Type | |
| --- | --- | --- |
| Steps | barchart | this week, weekday axis via `byType(time) → unit=time:ddd` |
| Steps to goal | stat | `clamp_min(70000 - sum_over_time(health_step[$__range]), 0)` |
| Weekly steps | ECharts | Mon-start calendar weeks summed in JS, 70K markLine |
| Weight (lbs) | ECharts | zeros filtered, gradient area |
| Step calendar | ECharts | GitHub-style contribution grid |

**Weekly buckets are computed in JavaScript, deliberately.** MetricsQL has no
calendar-week bucketing, and a `[7d]` step aligns to Unix epoch multiples —
epoch day 0 was a Thursday — so "weekly" points would land on Thursdays while
the goal stat counts Mon–Su. The JS also drops weeks clipped by the range edge
(a 1-day bucket is a partial week, not a bad week) and excludes the in-progress
week from the regression fit.

Trend lines are `range_linear_regression(...)` in MetricsQL, or inline least
squares in the ECharts panels where the fit needs a different point set than
the one plotted.

### Palette

Validated with the `dataviz` skill's `validate_palette.js` — do not eyeball
replacements, re-run it.

| Role | Hex |
| --- | --- |
| steps | `#3E63DD` |
| weight | `#12A594` |
| trend | `#E5484D` |
| goal line / axes | `#8B8D98` |
| calendar bands | `#E5484D` `#F5A524` `#6FD3A0` `#15784F` |

The calendar bands took three rounds: `#1B6E4B` failed the chroma floor (reads
gray) and an obvious green pair sat at ΔE 11.8, under the 15 normal-vision floor
— indistinguishable to everyone, not just colourblind viewers.

The steps-to-goal stat is coloured low-is-good with **absolute** thresholds, so
it reads red early in the week even when on pace. The user knows; they said
"Monday is supposed to be bad." Don't re-raise it.

## Verify before you ship

Three habits that each caught a real bug here:

- **Run queries against live VM over SSH before wiring them into a panel.**
  `ssh linode` then `curl -s -G localhost:8428/api/v1/query_range ...`.
- **Run panel JS in `node` over real exported data.** This is what caught the
  clipped-week artifact and the missing-day bug.
- **Read a plugin's `module.js` from `plugins-cdn.grafana.net` instead of
  guessing its option keys.** `grep -oE 'path:\s*"[a-zA-Z]+"'` gives the real
  list; it found two wrong keys and settled the threshold question outright.

There is no browser session logged into Grafana available, so rendering cannot
be verified directly — ask the user for a screenshot when appearance matters.

## Ingest format

`POST https://metrics.ltran.co/ingest`, `Authorization: Bearer $INGEST_TOKEN`:

```json
{ "step":   { "2026-07-25": 6151, "2026-07-26": "4999" },
  "weight": { "2026-07-25": 146.9 } }
```

Becomes `health_step{src="ios"}` and `health_weight{src="ios"}` — VictoriaMetrics
joins measurement and field with `_`. Timestamp keys accept `YYYY-MM-DD`,
RFC3339, or epoch seconds/millis; bare dates resolve in `LOCAL_TZ`
(`America/Los_Angeles`, correct — the user is on Pacific).

## Local development

```bash
docker build -t metrics-shim:test ./shim
mkdir -p /tmp/mtest && cp deploy/docker-compose.prod.yml /tmp/mtest/docker-compose.yml
echo 'INGEST_TOKEN=testtoken123' > /tmp/mtest/.env
cd /tmp/mtest && DOCKER_IMAGE=metrics-shim:test docker compose up -d

curl -s -X POST localhost:8081/ingest -H 'Authorization: Bearer testtoken123' \
  -d '{"step":{"2026-07-25":6151}}'
curl -s -G localhost:8428/api/v1/export --data-urlencode 'match[]={__name__=~"health.*"}' \
  --data-urlencode 'start=2026-07-01T00:00:00Z' --data-urlencode 'end=2026-08-01T00:00:00Z'
```
