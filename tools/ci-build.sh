#!/usr/bin/env bash
# Build half of .github/workflows/auto-update.yml (job `build`). It runs third-party build scripts, so
# it is read-only: no signing key, no write token, nothing pushed, no PR, no issue, no publish. It only
# produces data in $AUTO_UPDATE_OUT (default out/) for the publish job, which treats it as untrusted:
#   passed.tsv     status<TAB>pkg<TAB>version_revision that was built (status bump|unpublished)
#   failed.tsv     pkg<TAB>version
#   templates/<pkg>/template   the bumped template of each passing bump
#   xbps/*.xbps    packages built in this run
#   logs/<pkg>.log tail of the log of each failure
# Each package also gets the publish job's metadata checks right after it is built, so a package that would
# be rejected there fails here, with its log. It stops starting new packages after AUTO_UPDATE_BUDGET_MIN
# minutes (default 280, the job has 340), so what is built is always handed over; the rest is picked up by
# the next run. It hard-resets the work tree between packages, so it refuses to run outside GitHub Actions.
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] && [ -z "${CI_AUTO_UPDATE_FORCE:-}" ]; then
	echo "ci-build: refusing to run outside GitHub Actions" >&2
	exit 1
fi
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
. tools/ci-lib.sh

VL=${VOIDLAB_BIN:-./voidlab}
OUT=${AUTO_UPDATE_OUT:-out}
BUDGET_MIN=${AUTO_UPDATE_BUDGET_MIN:-280}
LOGDIR=$(mktemp -d)
log() { printf '=> %s\n' "$*"; }
tab=$'\t'

if [ -n "${INPUT_PKG:-}" ] && ! [[ $INPUT_PKG =~ ^[a-z0-9][a-z0-9._+-]*$ ]]; then
	echo "ci-build: invalid package name: $INPUT_PKG" >&2
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/templates" "$OUT/xbps" "$OUT/logs"
: > "$OUT/passed.tsv"
: > "$OUT/failed.tsv"

# xbps-src resolves build dependencies from hostdir/binpkgs, and a fresh CI checkout has none of
# the overlay's own libraries (glib, gtk4, ...) there: seed it from the pulled release. Only what an
# overlay template still makes: a stale release package of a name only Void builds now (dinit 0.22.1_1)
# is older than Void's template, so xbps-src would rebuild Void's package from source instead of
# installing Void's binary.
seed_binpkgs() {
	local f b
	shopt -s nullglob
	mkdir -p hostdir/binpkgs
	for f in repo/*.xbps; do
		b=${f##*/}
		[[ $b =~ ^(.+)-[0-9][0-9A-Za-z.+~]*_[0-9]+\.(x86_64|noarch)\.xbps$ ]] && owner_of "${BASH_REMATCH[1]}" >/dev/null || continue
		[ -e "hostdir/binpkgs/$b" ] || cp "$f" hostdir/binpkgs/
	done
	set -- hostdir/binpkgs/*.xbps
	shopt -u nullglob
	[ $# -eq 0 ] || { mapfile -t sorted < <(printf '%s\n' "$@" | sort -V); XBPS_ARCH=x86_64 xbps-rindex -f -a "${sorted[@]}" >/dev/null; }
}

repo_list() { (shopt -s nullglob; for f in repo/*.xbps; do echo "${f##*/}"; done | sort); }

"$VL" sync </dev/null || exit 1
"$VL" pull </dev/null || exit 1
name_map_load
seed_binpkgs || exit 1
plan=$("$VL" update --check ${INPUT_PKG:+"$INPUT_PKG"} </dev/null) || exit 1
printf '%s\n' "$plan"
# human-readable record of everything checked, so "nothing to do" is distinguishable from "did not look";
# written outside $OUT because the publish job validates $OUT strictly
SUMMARY=${AUTO_UPDATE_SUMMARY:-}
if [ -n "$SUMMARY" ]; then
	{
		echo '### auto-update: packages checked'
		echo
		echo '| status | package | ours | upstream |'
		echo '|---|---|---|---|'
		awk -F'\t' 'NF { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' <<<"$plan"
	} > "$SUMMARY"
fi

while IFS=$'\t' read -r -u 3 status pkg ours other; do
	case $status in
	fail) log "detection failed: $pkg: $other"; continue ;;
	bump | unpublished) ;;
	*) continue ;;
	esac
	if [ "$status" = bump ]; then ver=${other}_1; else ver=$ours; fi
	# a bump whose PR is already open (tier review, or a stuck auto merge) is not rebuilt every night
	if [ "$status" = bump ] && git ls-remote --exit-code --heads origin "autobump/$pkg-$other" </dev/null >/dev/null 2>&1; then
		log "autobump/$pkg-$other already exists: skipping $pkg"
		continue
	fi
	if [ "$SECONDS" -ge $((BUDGET_MIN * 60)) ]; then
		log "time budget of $BUDGET_MIN minutes used: $pkg is left for the next run"
		continue
	fi
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

	# the publish job's checks (tools/ci-lib.sh pkg_meta_problems), on everything new this build made
	new=$(comm -13 <(printf '%s\n' "$before") <(repo_list))
	problems=
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[[ $f =~ ^(.+)-[0-9][0-9A-Za-z.+~]*_[0-9]+\.(x86_64|noarch)\.xbps$ ]] || continue
		downer=$(owner_of "${BASH_REMATCH[1]}") || continue
		problems+=$(pkg_meta_problems repo "$f" "$downer" .upstream/common/shlibs common/shlibs)
	done <<<"$new"
	if [ -n "$problems" ]; then
		log "built, but would be rejected by the publish job: $pkg"
		printf '%s\n' "$problems"
		printf '%s\t%s\n' "$pkg" "${ver%_*}" >> "$OUT/failed.tsv"
		printf 'Built, but the packages do not pass the publish checks (tools/ci-lib.sh pkg_meta_problems):\n%s\n' "$problems" > "$OUT/logs/$pkg.log"
		continue
	fi

	# Everything new in repo/ goes into the artifact, including dependencies xbps-src had to build because
	# the lab is ahead of the release. A dependency owned by another overlay template is recorded as an
	# `unpublished` entry of that owner (the publish job validates it like any other); one owned by a
	# never-publish template is dropped; an unknown name is handed over and rejected there.
	never=$(list_names tools/never-publish)
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[[ $f =~ ^(.+)-([0-9][0-9A-Za-z.+~]*_[0-9]+)\.(x86_64|noarch)\.xbps$ ]] || { cp "repo/$f" "$OUT/xbps/"; continue; }
		dname=${BASH_REMATCH[1]} dvr=${BASH_REMATCH[2]}
		if grep -qxF -- "$dname" <<<"$(allowed_names "$pkg")"; then cp "repo/$f" "$OUT/xbps/"; continue; fi
		if downer=$(owner_of "$dname"); then
			if grep -qxF -- "$downer" <<<"$never"; then log "dependency $f is on the never-publish list: not handed over"; continue; fi
			if [ "$(template_verrev "$downer" 2>/dev/null)" != "$dvr" ]; then
				log "dependency $f is not the version of its template on main: not handed over"; continue
			fi
			cp "repo/$f" "$OUT/xbps/"
			if ! grep -qE "^unpublished${tab}${downer}${tab}" "$OUT/passed.tsv" 2>/dev/null; then
				printf 'unpublished\t%s\t%s\n' "$downer" "$dvr" >> "$OUT/passed.tsv"
				log "dependency built along the way: $downer $dvr"
			fi
		else
			# no overlay template makes this (an upstream package xbps-src had to build): it is not ours to publish,
			# and handing it over would make the publish job abort the whole run
			log "dependency $f has no overlay template: not handed over"
		fi
	done <<<"$new"
	if [ "$status" = bump ]; then
		mkdir -p "$OUT/templates/$pkg"
		cp "srcpkgs/$pkg/template" "$OUT/templates/$pkg/template"
	fi
	# its own entry replaces one recorded earlier when it was built as another package's dependency
	awk -F'\t' -v p="$pkg" '$2 != p' "$OUT/passed.tsv" > "$OUT/passed.tsv.new" && mv "$OUT/passed.tsv.new" "$OUT/passed.tsv"
	printf '%s\t%s\t%s\n' "$status" "$pkg" "$ver" >> "$OUT/passed.tsv"
done 3<<<"$plan"
git reset -q --hard </dev/null
log "passed: $(cut -f2 "$OUT/passed.tsv" | tr '\n' ' ')"
if [ -n "$SUMMARY" ]; then
	{
		echo
		echo "Passed: $(cut -f2 "$OUT/passed.tsv" | tr '\n' ' ')"
		echo "Failed: $(cut -f1 "$OUT/failed.tsv" | tr '\n' ' ')"
	} >> "$SUMMARY"
fi
