#!/usr/bin/env bash
# tools/ci-watchdog.sh: opens one issue when a scheduled workflow has not succeeded recently, closes it
# when healthy. Fake gh driven by files in $W.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
WD=$HERE/../tools/ci-watchdog.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

cat > "$W/gh" <<'X'
#!/usr/bin/env bash
echo "gh $*" >> "$W/calls"
case "$1 $2" in
"run list")
	wf=
	while [ $# -gt 0 ]; do [ "$1" = --workflow ] && wf=$2; shift; done
	cat "$W/last-${wf%.yml}" 2>/dev/null || true ;;
"issue list") cat "$W/open-issue" 2>/dev/null || true ;;
*) ;;
esac
X
chmod +x "$W/gh"
export W
export PATH=$W:$PATH WATCHDOG_NOW=2026-10-09T12:00:00Z GH_REPO=o/r

setup() { rm -f "$W"/last-* "$W/open-issue" "$W/calls"; : > "$W/calls"; }
run() { bash "$WD" 2>&1; }

# 1. both fresh, no open issue -> nothing created
setup
echo 2026-10-09T04:30:00Z > "$W/last-auto-update"
echo 2026-10-06T05:00:00Z > "$W/last-overlay-report"
out=$(run) && rc=0 || rc=$?
assert_eq "healthy exits 0" "$rc" "0"
assert_eq "healthy creates no issue" "$(grep -c 'issue create' "$W/calls" || true)" "0"

# 2. auto-update stale (>36h) -> issue created, names the workflow
setup
echo 2026-10-07T04:30:00Z > "$W/last-auto-update"
echo 2026-10-06T05:00:00Z > "$W/last-overlay-report"
out=$(run) && rc=0 || rc=$?
assert_eq "stale exits 0 (the issue is the signal)" "$rc" "0"
assert_eq "stale creates one issue" "$(grep -c 'issue create' "$W/calls" || true)" "1"
assert_grep "issue mentions auto-update" 'auto-update' "$W/calls"

# 3. never ran -> counts as stale
setup
echo 2026-10-09T04:30:00Z > "$W/last-auto-update"
out=$(run) && rc=0 || rc=$?
assert_eq "never-run overlay-report creates an issue" "$(grep -c 'issue create' "$W/calls" || true)" "1"
assert_grep "issue mentions overlay-report" 'overlay-report' "$W/calls"

# 4. already an open issue -> edited, not duplicated
setup
echo 2026-10-07T04:30:00Z > "$W/last-auto-update"
echo 2026-10-06T05:00:00Z > "$W/last-overlay-report"
echo 42 > "$W/open-issue"
out=$(run) && rc=0 || rc=$?
assert_eq "open issue is edited" "$(grep -c 'issue edit 42' "$W/calls" || true)" "1"
assert_eq "no duplicate issue" "$(grep -c 'issue create' "$W/calls" || true)" "0"

# 5. healthy again -> open issue closed
setup
echo 2026-10-09T04:30:00Z > "$W/last-auto-update"
echo 2026-10-06T05:00:00Z > "$W/last-overlay-report"
echo 42 > "$W/open-issue"
out=$(run) && rc=0 || rc=$?
assert_eq "healthy closes the open issue" "$(grep -c 'issue close 42' "$W/calls" || true)" "1"
finish
