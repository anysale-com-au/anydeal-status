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
