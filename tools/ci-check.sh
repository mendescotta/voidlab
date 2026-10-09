#!/usr/bin/env bash
# Pull-request gate for .github/workflows/check.yml. Read-only: lints what the change touches vs $BASE and
# runs the test suite. Never builds, never needs a token or a key, so it is safe for fork PRs too.
#   1. xlint on changed templates; findings must be listed in tools/xlint-known.txt (path: message)
#   2. changed templates do not hardcode their own version in distfiles/changelog/homepage
#   3. no -devel package in the runtime depends of a template
#   4. added or changed patches state a reason (a `Why:` line or a git-format `Subject:`)
#   5. every package a changed template depends on exists (overlay or Void's repositories) at a version
#      that satisfies its `>=` floor, and every subpackage has its srcpkgs/<name> symlink: these otherwise
#      only show up when CI builds it (skipped when Void's repositories cannot be queried)
#   6. tools/*.sh and ./voidlab parse; tests/test-*.sh pass (skip with CHECK_SKIP_TESTS=1)
set -uo pipefail
cd "${CHECK_ROOT:-$(dirname "$(readlink -f "$0")")/..}" || exit 1

. "$(dirname "$(readlink -f "$0")")/ci-lib.sh"
BASE=${BASE:-origin/main}
XQ=${XBPS_QUERY:-xbps-query}
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
	case $t in srcpkgs/gcc/* | srcpkgs/gcc-*/*) continue ;; esac
	if awk '
		/^[A-Za-z0-9._+-]+_package\(\)/ { sub_ = ($1 ~ /^[A-Za-z0-9._+-]*-devel_package/) }
		/^}/ { sub_ = 0 }
		/^[[:space:]]*depends[[:space:]]*\+?=/ && !sub_ { capture = 1 }
		capture { print }
		capture && /"[[:space:]]*$/ && !/=[[:space:]]*"[^"]*$/ { capture = 0 }
		capture && /=.*".*"/ { capture = 0 }' "$t" | grep -E -- '-devel([<>=[:space:]"]|$)' >/dev/null; then
		bad "$t lists a -devel package in runtime depends (belongs in makedepends)"
	fi
done

# dependencies: what a template names must exist, and a version floor must be reachable
declare -A REPO_VERS=()
avail_versions() { # <name>: the versions on offer, one per line: the overlay template's and the repositories'
	local o
	if o=${NAME_OWNER[$1]:-} && [ -n "$o" ]; then template_verrev "$o" 2>/dev/null; fi
	[ -z "${REPO_VERS[$1]:-}" ] || printf '%s' "${REPO_VERS[$1]}"
}
if [ ${#templates[@]} -gt 0 ] && index=$("$XQ" -R -s '' 2>/dev/null) && [ -n "$index" ]; then
	name_map_load
	# one listing of every repository package (`[-] name-version_revision  description`), not a query per name
	while read -r _ pv _; do
		[[ $pv =~ ^(.+)-([^-]+_[0-9]+)$ ]] && REPO_VERS[${BASH_REMATCH[1]}]+="${BASH_REMATCH[2]}"$'\n'
	done <<<"$index"
	for t in "${templates[@]}"; do
		[ -f "$t" ] || continue
		while IFS= read -r w; do
			case $w in '' | *'$'* | *'('* | *')'* | *'"'* | virtual\?* | *-bootstrap) continue ;; esac
			name=${w%%[<>=]*}
			[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
			vers=$(avail_versions "$name")
			if [ -z "$vers" ]; then bad "$t depends on $name, which neither the overlay nor Void's repositories have"; continue; fi
			case $w in
			*'>='* | *'>'*) floor=${w#*>}; floor=${floor#=}
				ok=
				while IFS= read -r v; do
					[ -n "$v" ] || continue
					xbps-uhelper cmpver "$v" "$floor" >/dev/null 2>&1; [ $? -ne 255 ] && ok=1
				done <<<"$vers"
				[ -n "$ok" ] || bad "$t needs $w, but only $(tr '\n' ' ' <<<"$vers")is on offer" ;;
			esac
		# plain assignments only: a `+=` is an arch or cross-build branch, and $(vopt_if ...) a build option
		done < <(perl -0ne 'while (/^[ \t]*(?:depends|makedepends|hostmakedepends|checkdepends)[ \t]*=[ \t]*(?:"([^"]*)"|\x27([^\x27]*)\x27)/mg) { my $v = defined $1 ? $1 : $2; $v =~ s/\$\([^)]*(?:\)|$)//g; print "$_\n" for split /\s+/, $v }' "$t" | sort -u)
		pkg=${t#srcpkgs/}; pkg=${pkg%/template}
		while IFS= read -r sub; do
			[ -n "$sub" ] || continue
			# Void's tree (merged in at build time) has the symlinks of the subpackages it ships
			[ -n "${REPO_VERS[$sub]:-}" ] && [ ! -e "srcpkgs/$sub" ] && continue
			[ -L "srcpkgs/$sub" ] && [ "$(readlink "srcpkgs/$sub")" = "$pkg" ] ||
				bad "$t declares subpackage $sub, which Void does not ship, but srcpkgs/$sub is not a symlink to $pkg"
		done < <(sed -n 's/^\([A-Za-z0-9._+-][A-Za-z0-9._+-]*\)_package[[:space:]]*(.*/\1/p' "$t")
	done
elif [ ${#templates[@]} -gt 0 ]; then
	echo "ci-check: Void's repositories cannot be queried: dependency check skipped"
fi

for p in "${patches[@]}"; do
	[ -f "$p" ] || continue
	grep -qE '^(# *)?Why:|^Subject:' <<<"$(head -n 30 "$p")" || bad "$p has no reason (add '# Why:', '# Upstream:', '# Drop when:' lines)"
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
