#!/usr/bin/env bash
# Weekly report for .github/workflows/overlay-report.yml: one issue listing overlay templates that
# official Void has caught up with (prefer official) and newer upstream releases that are not on
# the auto and review tiers (those are bumped by auto-update: auto merges, review opens a PR). Opens the issue, or edits the open one.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

VL=${VOIDLAB_BIN:-./voidlab}
TIERS=${VOIDLAB_TIERS:-tools/update-tiers}
export GH_REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}

"$VL" sync </dev/null || exit 1
red=$("$VL" redundant </dev/null) || exit 1
upd=$("$VL" update --all </dev/null) || exit 1
tiers=$(sed -e 's/#.*//' "$TIERS" 2>/dev/null | awk 'NF == 2 { print $1, $2 }')
tier_of() { awk -v p="$1" '$1 == p { print $2 }' <<<"$tiers"; }

rows=$(awk -F'\t' '$1 == "bump" { printf "%s\t%s\t%s\n", $2, $3, $4 }' <<<"$upd" |
	while IFS=$'\t' read -r p o n; do
		t=$(tier_of "$p")
		case $t in auto | review) ;; *) printf '| %s | %s | %s | %s |\n' "$p" "${t:-notify}" "$o" "$n" ;; esac
	done)

body=$(mktemp)
{
	echo '## Prefer official Void'
	echo
	if [ -n "$red" ]; then
		echo 'Overlay templates at the same version as, or behind, official Void. Drop the template so the official package wins, or add it to `tools/keep-overlay.list` with the reason (for example a rebuild against our newer libraries).'
		echo
		echo '| verdict | package | ours | official |'
		echo '|---|---|---|---|'
		awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' <<<"$red"
	else
		echo 'Nothing: every overlay template is ahead of official Void or kept on purpose.'
	fi
	echo
	echo '## New upstream releases (not auto-updated)'
	echo
	if [ -n "$rows" ]; then
		echo 'Packages with a newer stable upstream release that auto-update does not touch (tier `manual`, or not in `tools/update-tiers`). Libraries and stack packages usually need coordinated rebuilds, so bump them by hand, or give a leaf app the `review` or `auto` tier.'
		echo
		echo '| package | tier | ours | upstream |'
		echo '|---|---|---|---|'
		printf '%s\n' "$rows"
	else
		echo 'Nothing: no package outside the auto and review tiers has a newer stable release.'
	fi
} > "$body"

gh label create overlay-report --color 0E8A16 >/dev/null 2>&1 || true
n=$(gh issue list --state open --label overlay-report --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [ -n "$n" ]; then
	gh issue edit "$n" --body-file "$body"
else
	gh issue create --title "Overlay report" --label overlay-report --body-file "$body"
fi
