#!/usr/bin/env bash
# Pull-request gate for .github/workflows/check.yml. Read-only: lints what the change touches vs $BASE and
# runs the test suite. Never builds, never needs a token or a key, so it is safe for fork PRs too.
#   1. xlint on changed templates; findings must be listed in tools/xlint-known.txt (path: message)
#   2. changed templates do not hardcode their own version in distfiles/changelog/homepage
#   3. no -devel package in the runtime depends of a template
#   4. added or changed patches state a reason (a `Why:` line or a git-format `Subject:`)
#   5. tools/*.sh and ./voidlab parse; tests/test-*.sh pass (skip with CHECK_SKIP_TESTS=1)
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

# a *-devel package in runtime depends drags headers and static files onto every install; only a -devel
# subpackage, a compiler that ships them (gcc*) or a meta package may do that
for t in "${templates[@]}"; do
	[ -f "$t" ] || continue
	case $t in srcpkgs/gcc/* | srcpkgs/gcc-*/* | srcpkgs/libgccjit/*) continue ;; esac
	if awk '
		/^[A-Za-z0-9._+-]+_package\(\)/ { sub_ = ($1 ~ /^[A-Za-z0-9._+-]*-devel_package/) }
		/^}/ { sub_ = 0 }
		/^[[:space:]]*depends[[:space:]]*\+?=/ && !sub_ { capture = 1 }
		capture { print }
		capture && /"[[:space:]]*$/ && !/=[[:space:]]*"[^"]*$/ { capture = 0 }
		capture && /=.*".*"/ { capture = 0 }' "$t" | grep -qE -- '-devel([<>=[:space:]"]|$)'; then
		bad "$t lists a -devel package in runtime depends (belongs in makedepends)"
	fi
done

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
		if ! tout=$(bash "$t" 2>&1); then
			bad "$t failed"
			printf '%s\n' "$tout" | grep -v '^ok ' | tail -n 15 | sed 's/^/    /'
		fi
	done
fi

if [ "$fails" -gt 0 ]; then
	echo "ci-check: $fails problem(s)"
	exit 1
fi
echo "ci-check: ok (${#templates[@]} templates, ${#patches[@]} patches)"
