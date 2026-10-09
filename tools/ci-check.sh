#!/usr/bin/env bash
# Pull-request gate for .github/workflows/check.yml. Read-only: lints what the change touches vs $BASE and
# runs the test suite. Never builds, never needs a token or a key, so it is safe for fork PRs too.
#   1. xlint on changed templates; findings must be listed in tools/xlint-known.txt (path: message)
#   2. changed templates do not hardcode their own version in distfiles/changelog/homepage
#   3. added or changed patches state a reason (a `Why:` line or a git-format `Subject:`)
#   4. tools/*.sh and ./voidlab parse; tests/test-*.sh pass (skip with CHECK_SKIP_TESTS=1)
set -uo pipefail
cd "${CHECK_ROOT:-$(dirname "$(readlink -f "$0")")/..}" || exit 1

BASE=${BASE:-origin/main}
XLINT=${XLINT:-xlint}
KNOWN=${KNOWN:-tools/xlint-known.txt}
fails=0
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

git rev-parse --verify -q "$BASE" >/dev/null || { echo "ci-check: unknown base $BASE" >&2; exit 2; }
changed=$(git diff --name-status --no-renames "$BASE"...HEAD -- srcpkgs | awk -F'\t' '$1 != "D" { print $2 }')

templates=()
patches=()
while IFS= read -r f; do
	[ -n "$f" ] || continue
	case $f in
	srcpkgs/*/template) templates+=("$f") ;;
	srcpkgs/*/patches/*) patches+=("$f") ;;
	esac
done <<<"$changed"

known=$(sed -e 's/[[:space:]]*#.*//' -e 's/[[:space:]]*$//' "$KNOWN" 2>/dev/null | awk 'NF')

if [ ${#templates[@]} -gt 0 ]; then
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		norm=$(sed -E 's/^([^:]+):[0-9]+: /\1: /' <<<"$line")
		grep -Fxq -- "$norm" <<<"$known" || bad "xlint: $line"
	done < <("$XLINT" "${templates[@]}" 2>&1)

	for t in "${templates[@]}"; do
		[ -f "$t" ] || continue
		ver=$(sed -n 's/^version=//p' "$t" | head -n1 | tr -d "\"'")
		[ -n "$ver" ] || continue
		while IFS= read -r l; do
			stripped=$(sed -E 's/\$\{[^}]*\}//g' <<<"$l")
			if grep -Fq -- "$ver" <<<"$stripped"; then
				bad "$t hardcodes the version $ver (use \${version}): ${l:0:100}"
			fi
		done < <(grep -E '^(distfiles|changelog|homepage)=' "$t")
	done
fi

for p in "${patches[@]}"; do
	[ -f "$p" ] || continue
	head -n 30 "$p" | grep -qE '^(# *)?Why:|^Subject:' || bad "$p has no reason (add '# Why:', '# Upstream:', '# Drop when:' lines)"
done

for s in tools/*.sh voidlab; do
	[ -f "$s" ] || continue
	bash -n "$s" 2>/dev/null || bad "$s does not parse"
done

if [ -z "${CHECK_SKIP_TESTS:-}" ]; then
	for t in tests/test-*.sh; do
		bash "$t" >/dev/null 2>&1 || bad "$t failed"
	done
fi

if [ "$fails" -gt 0 ]; then
	echo "ci-check: $fails problem(s)"
	exit 1
fi
echo "ci-check: ok (${#templates[@]} templates, ${#patches[@]} patches)"
