#!/usr/bin/env bash
# Build half of .github/workflows/auto-update.yml (job `build`). It runs third-party build scripts, so
# it is read-only: no signing key, no write token, nothing pushed, no PR, no issue, no publish. It only
# produces data in $AUTO_UPDATE_OUT (default out/) for the publish job, which treats it as untrusted:
#   passed.tsv     status<TAB>pkg<TAB>version_revision that was built (status bump|unpublished)
#   failed.tsv     pkg<TAB>version
#   templates/<pkg>/template   the bumped template of each passing bump
#   xbps/*.xbps    packages built in this run
#   logs/<pkg>.log tail of the log of each failure
# It hard-resets the work tree between packages, so it refuses to run outside GitHub Actions.
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] && [ -z "${CI_AUTO_UPDATE_FORCE:-}" ]; then
	echo "ci-build: refusing to run outside GitHub Actions" >&2
	exit 1
fi
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

VL=${VOIDLAB_BIN:-./voidlab}
OUT=${AUTO_UPDATE_OUT:-out}
LOGDIR=$(mktemp -d)
log() { printf '=> %s\n' "$*"; }

if [ -n "${INPUT_PKG:-}" ] && ! [[ $INPUT_PKG =~ ^[a-z0-9][a-z0-9._+-]*$ ]]; then
	echo "ci-build: invalid package name: $INPUT_PKG" >&2
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/templates" "$OUT/xbps" "$OUT/logs"
: > "$OUT/passed.tsv"
: > "$OUT/failed.tsv"

# xbps-src resolves build dependencies from hostdir/binpkgs, and a fresh CI checkout has none of
# the overlay's own libraries (glib, gtk4, ...) there: seed it from the pulled release.
seed_binpkgs() {
	local f
	shopt -s nullglob
	mkdir -p hostdir/binpkgs
	for f in repo/*.xbps; do
		[ -e "hostdir/binpkgs/${f##*/}" ] || cp "$f" hostdir/binpkgs/
	done
	set -- hostdir/binpkgs/*.xbps
	shopt -u nullglob
	[ $# -eq 0 ] || XBPS_ARCH=x86_64 xbps-rindex -f -a "$@" >/dev/null
}

repo_list() { (shopt -s nullglob; for f in repo/*.xbps; do echo "${f##*/}"; done | sort); }

"$VL" sync </dev/null || exit 1
"$VL" pull </dev/null || exit 1
seed_binpkgs || exit 1
plan=$("$VL" update --check ${INPUT_PKG:+"$INPUT_PKG"} </dev/null) || exit 1
printf '%s\n' "$plan"

while IFS=$'\t' read -r -u 3 status pkg ours other; do
	case $status in
	fail) log "detection failed: $pkg: $other"; continue ;;
	bump | unpublished) ;;
	*) continue ;;
	esac
	if [ "$status" = bump ]; then ver=${other}_1; else ver=$ours; fi
	log "$status: $pkg $ver"

	git reset -q --hard </dev/null
	if [ "$status" = bump ]; then
		res=$("$VL" update "$pkg" </dev/null)
		if grep -q '^fail' <<<"$res" || git diff --quiet -- "srcpkgs/$pkg"; then
			log "bump of $pkg did not change its template: $res"
			continue
		fi
	fi

	before=$(repo_list)
	# upstream build scripts are third-party code: they get no GitHub token and no signing key
	if ! { env -u GH_TOKEN -u GITHUB_TOKEN -u VOIDLAB_PRIVKEY "$VL" build "$pkg" &&
		env -u GH_TOKEN -u GITHUB_TOKEN -u VOIDLAB_PRIVKEY "$VL" test "$pkg"; } </dev/null >"$LOGDIR/$pkg.log" 2>&1; then
		log "build or test failed: $pkg"
		printf '%s\t%s\n' "$pkg" "${ver%_*}" >> "$OUT/failed.tsv"
		tail -n 40 "$LOGDIR/$pkg.log" > "$OUT/logs/$pkg.log"
		continue
	fi

	while IFS= read -r f; do
		[ -n "$f" ] && cp "repo/$f" "$OUT/xbps/"
	done < <(comm -13 <(printf '%s\n' "$before") <(repo_list))
	if [ "$status" = bump ]; then
		mkdir -p "$OUT/templates/$pkg"
		cp "srcpkgs/$pkg/template" "$OUT/templates/$pkg/template"
	fi
	printf '%s\t%s\t%s\n' "$status" "$pkg" "$ver" >> "$OUT/passed.tsv"
done 3<<<"$plan"
git reset -q --hard </dev/null
log "passed: $(cut -f2 "$OUT/passed.tsv" | tr '\n' ' ')"
