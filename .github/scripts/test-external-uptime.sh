#!/usr/bin/env bash
# .github/scripts/test-external-uptime.sh — local test harness for external-uptime.sh.
#
# No network, no GitHub: a tiny python HTTP server on a random localhost port
# plays the endpoints (/ok -> 200, /down -> 503, /flaky -> 503 twice then 200,
# /forbidden -> 403 like the Cloud Armor geo-fence on the apex),
# and a fake `gh` on PATH records every call and keeps one issue's state in a
# temp dir. Run:  bash .github/scripts/test-external-uptime.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/external-uptime.sh"
WORK=$(mktemp -d)
pass=0; fail=0

cleanup() { [[ -n "${SRV_PID:-}" ]] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; rm -rf "$WORK"; }
trap cleanup EXIT

# ── stub HTTP server ────────────────────────────────────────────────────────
cat >"$WORK/server.py" <<'PY'
import http.server, sys
hits = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits[self.path] = hits.get(self.path, 0) + 1
        with open(sys.argv[1], "a") as f: f.write(self.path + "\n")
        if self.path == "/ok": code = 200
        elif self.path == "/forbidden": code = 403
        elif self.path == "/flaky": code = 503 if hits[self.path] <= 2 else 200
        else: code = 503
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$WORK/server.py" "$WORK/hits" >"$WORK/port" &
SRV_PID=$!
for _ in $(seq 50); do [[ -s "$WORK/port" ]] && break; python3 -c 'import time; time.sleep(0.1)'; done
PORT=$(cat "$WORK/port")
OK="http://127.0.0.1:$PORT/ok"; DOWN="http://127.0.0.1:$PORT/down"; DOWN2="http://127.0.0.1:$PORT/down2"
FORBIDDEN="http://127.0.0.1:$PORT/forbidden"

# ── fake gh ─────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
S="$GH_FAKE_STATE"; echo "$*" >>"$S/calls"
bf=""; title=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--body-file" ]] && bf="$a"
  [[ "$prev" == "--title" ]] && title="$a"
  prev="$a"
done
case "$1 $2" in
  "issue list")    [[ -f "$S/open" ]] && cat "$S/open"; exit 0 ;;
  "issue view")    cat "$S/text"; exit 0 ;;
  "issue create")  echo 101 >"$S/open"; cp "$bf" "$S/text"; echo "$title" >"$S/title"; cp "$bf" "$S/created_body"; exit 0 ;;
  "issue comment") printf '\n' >>"$S/text"; cat "$bf" >>"$S/text"; cp "$bf" "$S/last_comment"; exit 0 ;;
  "issue close")   rm -f "$S/open"; exit 0 ;;
  "label create")  exit 0 ;;
esac
echo "fake gh: unhandled $*" >&2; exit 1
SH
chmod +x "$WORK/bin/gh"

reset_state() { rm -rf "$WORK/state"; mkdir -p "$WORK/state"; : >"$WORK/state/calls"; }
run() {  # run ENDPOINTS [extra env...]
  local eps="$1"; shift
  env PATH="$WORK/bin:$PATH" GH_FAKE_STATE="$WORK/state" GITHUB_REPOSITORY="o/r" \
    ENDPOINTS="$eps" BACKOFF_SECONDS="0 0" TIMEOUT=3 GITHUB_STEP_SUMMARY="" "$@" \
    bash "$SCRIPT" >"$WORK/out" 2>&1
}
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; sed 's/^/      /' "$WORK/out"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
calls() { grep -c "^issue $1" "$WORK/state/calls" || true; }

echo "=== all up, no issue -> nothing opened ==="
reset_state; run "$OK"; rc=$?
check "exit 0" '[[ $rc -eq 0 ]]'
check "no issue created" '[[ $(calls create) -eq 0 && $(calls comment) -eq 0 ]]'

echo "=== one down, no issue -> issue opened with billing line + mention ==="
: >"$WORK/hits"; reset_state; run "$OK $DOWN"; rc=$?
check "exit 0 even though prod is down" '[[ $rc -eq 0 ]]'
check "one issue created" '[[ $(calls create) -eq 1 ]]'
check "title names the failing endpoint" 'grep -qF "🔴 PROD DOWN — $DOWN" "$WORK/state/title"'
check "title does not name the healthy endpoint" '! grep -qF "$OK" "$WORK/state/title"'
check "body has the billing-first line" 'grep -qF "All services 503 in BOTH projects? Check GCP billing FIRST (account 01BAF5-AC1706-202B97)" "$WORK/state/created_body"'
check "body mentions @anysaleau" 'grep -qF "@anysaleau" "$WORK/state/created_body"'
check "body records status code 503" 'grep -qE "\| DOWN \| 503 \| [0-9T:-]+Z \|" "$WORK/state/created_body"'
check "issue labelled outage" 'grep -q "issue create.*--label outage" "$WORK/state/calls"'
check "down endpoint retried exactly 3 times" '[[ $(grep -c "^/down$" "$WORK/hits") -eq 3 ]]'
check "healthy endpoint probed once" '[[ $(grep -c "^/ok$" "$WORK/hits") -eq 1 ]]'

echo "=== still down, same set -> no comment (no spam) ==="
run "$OK $DOWN"
check "no comment" '[[ $(calls comment) -eq 0 && $(calls create) -eq 1 ]]'

echo "=== set changes -> exactly one comment ==="
run "$DOWN2 $DOWN"
check "one comment" '[[ $(calls comment) -eq 1 && $(calls create) -eq 1 ]]'
check "comment names the new set" 'grep -qF "$DOWN2" "$WORK/state/last_comment"'
run "$DOWN2 $DOWN"
check "unchanged again -> still one comment" '[[ $(calls comment) -eq 1 ]]'

echo "=== recovery -> comment + close ==="
run "$OK"
check "recovery comment" 'grep -q "Recovered" "$WORK/state/last_comment"'
check "issue closed" '[[ $(calls close) -eq 1 && ! -f "$WORK/state/open" ]]'
run "$OK"
check "next run after recovery is quiet" '[[ $(calls close) -eq 1 && $(calls comment) -eq 2 ]]'

echo "=== flaky (503,503,200) -> up, no issue (anti-flap) ==="
reset_state; run "http://127.0.0.1:$PORT/flaky"
check "no issue for a flap" '[[ $(calls create) -eq 0 ]]'

echo "=== connection refused -> code 000 recorded ==="
reset_state; run "http://127.0.0.1:9/nothing"
check "issue created" '[[ $(calls create) -eq 1 ]]'
check "code 000" 'grep -qE "\| DOWN \| 000 \|" "$WORK/state/created_body"'

echo "=== FORCE_FAILURE=true -> test issue even with prod up ==="
reset_state; run "$OK" FORCE_FAILURE=true
check "issue created" '[[ $(calls create) -eq 1 ]]'
check "marked as a forced test" 'grep -q "FORCED-FAILURE TEST" "$WORK/state/created_body"'
check "title names the forced endpoint" 'grep -qF "127.0.0.1:9/forced-failure-test" "$WORK/state/title"'
run "$OK"
check "next normal run closes it" '[[ $(calls close) -eq 1 ]]'

echo "=== apex behind Cloud Armor: 403 with |403 suffix -> edge up, no issue ==="
: >"$WORK/hits"; reset_state; run "$OK $FORBIDDEN|403"; rc=$?
check "exit 0" '[[ $rc -eq 0 ]]'
check "no issue for a geo-fence 403" '[[ $(calls create) -eq 0 ]]'
check "reported as edge-up with code 403" 'grep -qE "^edge-up 403 [0-9T:-]+Z $FORBIDDEN$" "$WORK/out"'
check "accepted 403 is not retried" '[[ $(grep -c "^/forbidden$" "$WORK/hits") -eq 1 ]]'

echo "=== 403 WITHOUT the suffix -> still DOWN (strict by default) ==="
reset_state; run "$FORBIDDEN"
check "issue created" '[[ $(calls create) -eq 1 ]]'
check "code 403 recorded" 'grep -qE "\| DOWN \| 403 \|" "$WORK/state/created_body"'

echo "=== edge endpoint answering 503 (billing closure at the LB) -> DOWN ==="
: >"$WORK/hits"; reset_state; run "$OK $DOWN|403"
check "issue created" '[[ $(calls create) -eq 1 ]]'
check "title shows the bare URL, not the |403 suffix" 'grep -qF "🔴 PROD DOWN — $DOWN" "$WORK/state/title" && ! grep -qF "|403" "$WORK/state/title"'
check "503 recorded" 'grep -qE "\| DOWN \| 503 \|" "$WORK/state/created_body"'
check "503 retried 3 times" '[[ $(grep -c "^/down$" "$WORK/hits") -eq 3 ]]'
run "$OK $DOWN|403"
check "same set next run -> no comment (marker uses bare URL)" '[[ $(calls comment) -eq 0 ]]'
run "$OK $FORBIDDEN|403"
check "back to 403 -> recovered + closed" '[[ $(calls close) -eq 1 ]] && grep -q "Recovered" "$WORK/state/last_comment"'

echo "=== default targets: canonical API health + apex as edge-only ==="
defaults=$(sed -n 's/^ENDPOINTS="\${ENDPOINTS:-\(.*\)}"$/\1/p' "$SCRIPT")
check "primary is au.api.anydeal.today/api/health" '[[ " $defaults " == *" https://au.api.anydeal.today/api/health "* ]]'
check "apex accepts the Cloud Armor 403" '[[ " $defaults " == *" https://anydeal.today/|403 "* ]]'
check "api.anydeal.today/healthz no longer probed" '[[ "$defaults" != *"/healthz"* ]]'
check "no target outside AU-fenced apex accepts 403" '[[ $(grep -o "|403" <<<"$defaults" | wc -l) -eq 1 ]]'

echo "=== gh failure -> non-zero exit (broken alarm is visible) ==="
reset_state; chmod -x "$WORK/bin/gh"
env PATH="$WORK/bin:/usr/bin:/bin" GH_FAKE_STATE="$WORK/state" GITHUB_REPOSITORY="o/r" ENDPOINTS="$DOWN" \
  BACKOFF_SECONDS="0 0" TIMEOUT=3 bash "$SCRIPT" >"$WORK/out" 2>&1; rc=$?
chmod +x "$WORK/bin/gh"
check "exit non-zero" '[[ $rc -ne 0 ]]'

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
