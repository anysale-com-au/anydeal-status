# anydeal-status

Public status page for **https://status.anydeal.today**, served by GitHub Pages.

**This repo is a publishing target, not the source of truth.** The page is
authored and reviewed in the private infra repo at
`anydeal-today-infra/status-page/`, which also carries the incident-update
procedure and the "what this page must never contain" rules. Change it there
first, then copy `index.html` here.

## Why it is hosted here and not on GCP

A status page must not share a failure domain with the platform it reports on.
Serving it from the Anydeal load balancer would take it down in exactly the
outage it exists to explain, and no TLS certificate covers this hostname on that
load balancer. GitHub Pages is off-GCP and terminates its own TLS.

## Updating during an incident

Edit the single block in `index.html` marked `EDIT DURING AN INCIDENT`, commit,
push. Pages redeploys in about a minute. Wording templates are in the incident
runbook (§8) in the brain repo — keep it plain customer language, and never post
revision ids, service names, log excerpts, customer data, or speculation about
cause.

`index.html` is deliberately self-contained: no CDN, no webfont, no external
script, no analytics, no JavaScript. A status page that loads assets from
somewhere else can fail with that somewhere else.

## Off-GCP outage alarm (`.github/workflows/external-uptime.yml`)

Every 5 minutes GitHub Actions probes `https://au.api.anydeal.today/api/health`
(the canonical API health check: Mongo + Redis, not geo-fenced) and
`https://anydeal.today/` (edge only, see the caveat on Cloud Armor). Each endpoint gets 3 attempts with backoff (10 s, then
20 s) and a 15 s timeout per attempt, so a single blip does not alert. If an
endpoint is still down, the workflow opens one issue labelled `outage`, titled
`🔴 PROD DOWN — <endpoint>`, and @-mentions `anysaleau`, so GitHub sends an
email and a mobile push. While that issue is open, it comments only when the
set of failing endpoints changes. When everything answers again, it comments
and closes the issue.

Why it is here: on 2026-10-09 the GCP billing account was closed and every
service in both projects returned 503. A Cloud Monitoring uptime check stops
when the billing account it runs on is closed, so this alarm runs outside GCP.
**All services 503 in BOTH projects? Check GCP billing FIRST (account
01BAF5-AC1706-202B97).**

**Prove the alarm works (do this once after merge, and after any change):**
Actions → *External uptime (off-GCP)* → *Run workflow* → tick
`force_failure` → *Run*. Or run
`gh workflow run external-uptime.yml -R anysale-com-au/anydeal-status -f force_failure=true`.
Within a minute an issue titled `🔴 PROD DOWN — http://127.0.0.1:9/forced-failure-test`
opens and you get the mention. The next scheduled run, about 5 minutes later
(GitHub cron can lag), comments "Recovered" and closes it.

**Local test** (no network or GitHub needed; a stub server and a fake `gh`):
`bash .github/scripts/test-external-uptime.sh`

**Caveats:**
- GitHub cron is best-effort. Runs can start 5–15 min late, and some are
  dropped when GitHub is under load. Expect to hear about an outage within
  about 10–25 min, not 5.
- GitHub disables scheduled workflows in a repo with no activity for 60 days.
  The monthly `keepalive` job re-enables the workflow through the API to reset
  that clock. If it is ever disabled anyway, re-enable it under Actions →
  *External uptime (off-GCP)* → *Enable workflow*.
- This repo is **public**, so outage issues are public. They contain only
  endpoint URLs, HTTP codes and timestamps. Never add internal details to them
  by hand.
- The alarm runs on GitHub. If GitHub itself is down, it stays silent.
- **The apex is only checked at the edge.** `anydeal.today` sits behind the
  Cloud Armor policy `phased-rollout-policy` (allow AU/NZ/IN, default
  `deny(403)`). GitHub-hosted runners are outside Australia, so they always get
  that 403. The apex entry is `https://anydeal.today/|403`: a 403 counts as
  *edge-up* (DNS, TLS and the load balancer are answering), and anything else
  that isn't 2xx/3xx is DOWN. That includes the 503 the load balancer returned
  when billing closed. The trade-off is that a broken frontend behind the fence
  is invisible from here. The API check covers the backend. **Do not add a
  Cloud Armor allow rule for the runners.**
