#!/usr/bin/env bash
# .github/scripts/external-uptime.sh — OFF-GCP prod outage alarm.
#
# Why this lives on GitHub and not in Cloud Monitoring: on 2026-10-09 the GCP
# billing account was closed and every service in BOTH projects returned 503.
# Any GCP-hosted uptime check dies with the billing account, so the alarm for
# that failure mode has to run somewhere else.
#
# Behaviour (one run):
#   1. Probe every endpoint: up to ATTEMPTS tries, sleeping BACKOFF_SECONDS
#      between tries (anti-flap), TIMEOUT seconds each. 2xx/3xx = up.
#      An entry written `URL|403` also accepts 403 as "edge-up" (see below).
#   2. Something down + no open `outage` issue  -> open one (mentions $MENTION).
#      Something down + open issue, same set    -> do nothing (no spam).
#      Something down + open issue, set changed -> comment with the new set.
#   3. Everything up + open `outage` issue      -> comment "recovered" + close.
#
# Exit code: 0 when the alarm did its job (even if prod is DOWN — the issue is
# the alert; a red run every 5 min would only add email noise). Non-zero only
# when the alarm itself could not talk to GitHub, so a broken alarm is visible.
#
# Env (all optional except GITHUB_REPOSITORY / GH_TOKEN in CI):
#   ENDPOINTS        space-separated `URL` or `URL|<code>,<code>` entries;
#                    extra codes count as edge-up (default: API health + apex)
#   ATTEMPTS         tries per endpoint     (default 3)
#   BACKOFF_SECONDS  sleeps between tries   (default "10 20")
#   TIMEOUT          per-try seconds        (default 15)
#   MENTION          GitHub user to @       (default anysaleau)
#   FORCE_FAILURE    "true" adds an endpoint that can never answer (alarm test)
#   RUN_URL          link to this run, put in the issue
set -uo pipefail

# Targets (verified 2026-10-15 against the prod URL map + Cloud Armor):
#  - au.api.anydeal.today/api/health: canonical deep health (mongo + redis),
#    api-backend-service, NOT geo-fenced -> must be 2xx/3xx from anywhere.
#  - anydeal.today/: prod-global-backend-service behind Cloud Armor
#    `phased-rollout-policy` (allow AU/NZ/IN, default deny(403)). GitHub-hosted
#    runners are outside AU, so they always get Cloud Armor's 403. A 403 still
#    proves DNS + TLS + the LB are serving ("edge-up"); the billing-closure
#    symptom (2026-10-09) is a 503 at the LB, which stays DOWN. Blind spot: a
#    broken frontend Cloud Run behind the fence is NOT visible from here.
#    Do not add a Cloud Armor allow rule for the runners to "fix" that.
ENDPOINTS="${ENDPOINTS:-https://au.api.anydeal.today/api/health https://anydeal.today/|403}"
ATTEMPTS="${ATTEMPTS:-3}"
BACKOFF_SECONDS="${BACKOFF_SECONDS:-10 20}"
TIMEOUT="${TIMEOUT:-15}"
MENTION="${MENTION:-anysaleau}"
FORCE_FAILURE="${FORCE_FAILURE:-false}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
RUN_URL="${RUN_URL:-}"
LABEL="outage"
# Port 9 (discard) on loopback: nothing listens on a runner, so this is a
# guaranteed connection failure that touches no real system.
FORCED_URL="http://127.0.0.1:9/forced-failure-test"
BILLING_LINE="All services 503 in BOTH projects? Check GCP billing FIRST (account 01BAF5-AC1706-202B97)"

if [[ "$FORCE_FAILURE" == "true" ]]; then
  ENDPOINTS="$ENDPOINTS $FORCED_URL"
fi

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# probe URL [EXTRA_CODES] -> prints "<last_http_code> <utc_timestamp>";
# returns 0 if up (2xx/3xx), 3 if edge-up (code in comma-list EXTRA_CODES),
# 1 if down. An accepted code ends the retries like a 2xx does.
probe() {
  local url="$1" extra=",${2:-}," code="000" i sleeps
  read -r -a sleeps <<<"$BACKOFF_SECONDS"
  for ((i = 1; i <= ATTEMPTS; i++)); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
      -A "anydeal-external-uptime (+https://github.com/$REPO)" "$url" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    if [[ "$code" -ge 200 && "$code" -lt 400 ]]; then
      echo "$code $(now)"
      return 0
    fi
    if [[ "$extra" == *",$code,"* ]]; then
      echo "$code $(now)"
      return 3
    fi
    if ((i < ATTEMPTS)); then
      sleep "${sleeps[$((i - 1))]:-${sleeps[${#sleeps[@]} - 1]:-0}}"
    fi
  done
  echo "$code $(now)"
  return 1
}

failing=()   # URLs that are down
table=""     # markdown rows for every endpoint
for entry in $ENDPOINTS; do
  url="${entry%%|*}"; extra=""
  [[ "$entry" == *"|"* ]] && extra="${entry#*|}"
  result=$(probe "$url" "$extra"); rc=$?
  case $rc in
    0) state="up" ;;
    3) state="edge-up" ;;
    *) state="DOWN"; failing+=("$url") ;;
  esac
  read -r code ts <<<"$result"
  table+="| \`$url\` | $state | $code | $ts |"$'\n'
  echo "$state $code $ts $url"
done

failing_set=""
if ((${#failing[@]})); then
  failing_set=$(printf '%s\n' "${failing[@]}" | sort | paste -sd, -)
fi

open_issue=$(gh issue list --repo "$REPO" --label "$LABEL" --state open --limit 1 \
  --json number --jq '.[0].number // empty') || { echo "::error::cannot list issues"; exit 2; }

marker() { printf '<!-- failing-set: %s -->' "$1"; }
header="| Endpoint | State | Last HTTP code | Checked (UTC) |"$'\n'"|---|---|---|---|"$'\n'
run_line=""
[[ -n "$RUN_URL" ]] && run_line="Probe run: $RUN_URL"
test_line=""
[[ "$FORCE_FAILURE" == "true" ]] && test_line="**This is a FORCED-FAILURE TEST of the alarm (workflow_dispatch). The next normal run will close it.**"$'\n\n'

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

if [[ -n "$failing_set" ]]; then
  if [[ -z "$open_issue" ]]; then
    gh label create "$LABEL" --repo "$REPO" --color B60205 \
      --description "Prod outage detected by the off-GCP probe" >/dev/null 2>&1 || true
    {
      printf '%s' "$test_line"
      printf '@%s prod endpoint(s) failing from the off-GCP probe (3 attempts with backoff, %ss timeout each).\n\n' "$MENTION" "$TIMEOUT"
      printf '%s%s\n' "$header" "$table"
      printf '**%s**\n\n' "$BILLING_LINE"
      printf 'Rollback/redeploy is useless until billing is restored. Runbook: anydeal-today-brain docs/050-Ops/Incident-Response-Runbook.md\n\n'
      [[ -n "$run_line" ]] && printf '%s\n\n' "$run_line"
      marker "$failing_set"; printf '\n'
    } >"$body_file"
    title="🔴 PROD DOWN — ${failing_set//,/, }"
    gh issue create --repo "$REPO" --title "$title" --label "$LABEL" --body-file "$body_file" \
      || { echo "::error::cannot open outage issue"; exit 2; }
    echo "opened outage issue: $title"
  else
    text=$(gh issue view "$open_issue" --repo "$REPO" --json body,comments \
      --jq '([.body] + [.comments[].body]) | join("\n")') || { echo "::error::cannot read issue"; exit 2; }
    last_set=$(grep -o '<!-- failing-set: [^>]* -->' <<<"$text" | tail -1 \
      | sed -e 's/^<!-- failing-set: //' -e 's/ -->$//')
    if [[ "$last_set" == "$failing_set" ]]; then
      echo "outage issue #$open_issue already open for the same set — no comment"
    else
      {
        printf '@%s failing set changed: now **%s** (was %s).\n\n' "$MENTION" "${failing_set//,/, }" "${last_set:-none}"
        printf '%s%s\n' "$header" "$table"
        printf '**%s**\n\n' "$BILLING_LINE"
        [[ -n "$run_line" ]] && printf '%s\n\n' "$run_line"
        marker "$failing_set"; printf '\n'
      } >"$body_file"
      gh issue comment "$open_issue" --repo "$REPO" --body-file "$body_file" \
        || { echo "::error::cannot comment"; exit 2; }
      echo "commented on #$open_issue: failing set changed"
    fi
  fi
else
  if [[ -n "$open_issue" ]]; then
    {
      printf '✅ Recovered — all endpoints answering at %s.\n\n' "$(now)"
      printf '%s%s\n' "$header" "$table"
      [[ -n "$run_line" ]] && printf '%s\n\n' "$run_line"
      marker ""; printf '\n'
    } >"$body_file"
    gh issue comment "$open_issue" --repo "$REPO" --body-file "$body_file" \
      || { echo "::error::cannot comment"; exit 2; }
    gh issue close "$open_issue" --repo "$REPO" || { echo "::error::cannot close"; exit 2; }
    echo "closed outage issue #$open_issue (recovered)"
  else
    echo "all endpoints up"
  fi
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { printf '%s%s' "$header" "$table"; } >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
