#!/usr/bin/env bash
# Daily check for .github/workflows/watchdog.yml: a schedule that silently stops looks the same as "no
# updates". Opens (or edits) one `ci-watchdog` issue when auto-update has no successful scheduled run in
# the last 36 h or overlay-report none in the last 9 days, and closes it when both are healthy again.
set -uo pipefail

export GH_REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}
now=$(date -u -d "${WATCHDOG_NOW:-now}" +%s)

problems=""
check() { # workflow file, max age in hours
	local wf=$1 max=$2 last first ts age
	last=$(gh run list --workflow "$wf.yml" --event schedule --status success --limit 1 --json createdAt --jq '.[0].createdAt // empty' 2>/dev/null || true)
	if [ -z "$last" ]; then
		# a workflow younger than its limit may simply not have reached its first scheduled run yet
		first=$(gh run list --workflow "$wf.yml" --limit 500 --json createdAt --jq '.[-1].createdAt // empty' 2>/dev/null || true)
		if [ -n "$first" ] && [ $(((now - $(date -u -d "$first" +%s)) / 3600)) -le "$max" ]; then return; fi
		problems+="- \`$wf\`: no successful scheduled run found"$'\n'
		return
	fi
	ts=$(date -u -d "$last" +%s)
	age=$(((now - ts) / 3600))
	if [ "$age" -gt "$max" ]; then
		problems+="- \`$wf\`: last successful scheduled run $last (${age}h ago, limit ${max}h)"$'\n'
	fi
}

check auto-update 36
check overlay-report 216

n=$(gh issue list --state open --label ci-watchdog --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [ -n "$problems" ]; then
	body=$(printf 'Scheduled workflows are not running as expected:\n\n%s\nCheck the Actions tab (a disabled schedule, an expired token or a failing job all look like this). This issue closes itself when both are healthy.\n' "$problems")
	gh label create ci-watchdog --color D93F0B >/dev/null 2>&1 || true
	if [ -n "$n" ]; then
		gh issue edit "$n" --body "$body"
	else
		gh issue create --title "CI watchdog: scheduled workflow not running" --label ci-watchdog --body "$body"
	fi
elif [ -n "$n" ]; then
	gh issue close "$n" --comment "Both scheduled workflows are healthy again."
fi
exit 0
