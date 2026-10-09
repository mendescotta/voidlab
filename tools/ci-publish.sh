#!/usr/bin/env bash
# Publish half of .github/workflows/auto-update.yml (job `publish`): the only place with a write token
# and the signing key. It never runs anything from the build job: $BUILD_OUT (the downloaded artifact)
# is untrusted DATA, validated strictly before anything is pushed, merged or signed. A deviation in the
# artifact itself aborts the whole run:
#   - only these files, no symlinks: passed.tsv failed.tsv templates/<n>/template xbps/<n>.xbps logs/<n>.log
#   - passed.tsv: `bump|unpublished<TAB>pkg<TAB>version_revision`. A bump needs the auto or review tier (or
#     INPUT_PKG). `unpublished` (a template already on main that the release lacks, also a dependency CI had to
#     build along the way) may be any tier, but never a template on tools/never-publish
#   - a package file must be the passed package or one of its declared subpackages, at the passed version,
#     and its metadata must match its file name
# A deviation of one template only rejects that template (and any other in this run that needs it); the
# rest is published, each rejection gets an issue and the run ends with an error:
#   - a bumped template may differ from main only in its version, revision and checksum lines
#   - provides, replaces, conflicts, alternatives and sonames must come from the template or its files
#     (tools/ci-lib.sh pkg_meta_problems)
# Then: one PR per bump (merged), failures become issues, the packages are added to the pulled release
# and `voidlab publish` signs and uploads. It hard-resets the work tree, so it refuses to run elsewhere.
set -uo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] && [ -z "${CI_AUTO_UPDATE_FORCE:-}" ]; then
	echo "ci-publish: refusing to run outside GitHub Actions" >&2
	exit 1
fi
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

# one byte-wise locale: character classes and ranges must mean the same thing everywhere
export LC_ALL=C

die() { echo "ci-publish: $*" >&2; exit 1; }
log() { printf '=> %s\n' "$*"; }
declare -A REJECTED=()
# reject <template> <reason>: keep that template's packages out of this release (reported as an issue)
reject() { log "rejected $1: $2"; REJECTED[$1]+="$2"$'\n'; }

VL=${VOIDLAB_BIN:-./voidlab}
BASE=${BASE_BRANCH:-main}
BUILD_OUT=${BUILD_OUT:-}
export VOIDLAB_KEY=${VOIDLAB_KEY:-$HOME/.config/voidlab/privkey.pem}
export GH_REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}
[ -n "$BUILD_OUT" ] && [ -d "$BUILD_OUT" ] || die "BUILD_OUT must be the downloaded build artifact directory"

. tools/ci-lib.sh
NAME_RE='[A-Za-z0-9][A-Za-z0-9._+~-]*'
PKG_RE='^[a-z0-9][a-z0-9._+-]*$'
VER_RE='[0-9][0-9A-Za-z.+~]*'
VERREV_RE="^${VER_RE}_[0-9]+\$"
HASH_RE='[0-9a-f]{64}'

[ -z "${INPUT_PKG:-}" ] || [[ $INPUT_PKG =~ $PKG_RE ]] || die "invalid INPUT_PKG"

# --- layout: only the expected files, no links, no special files
[ -z "$(find "$BUILD_OUT" -type l -print -quit)" ] || die "symlink in the build artifact"
[ -z "$(find "$BUILD_OUT" ! -type f ! -type d -print -quit)" ] || die "special file in the build artifact"
layout_re="^(passed\.tsv|failed\.tsv|templates/$NAME_RE/template|xbps/$NAME_RE\.xbps|logs/$NAME_RE\.log)\$"
while IFS= read -r f; do
	rel=${f#"$BUILD_OUT"/}
	[[ $rel =~ $layout_re ]] || die "unexpected file in the build artifact: $rel"
done < <(find "$BUILD_OUT" -type f)
[ -f "$BUILD_OUT/passed.tsv" ] && [ -f "$BUILD_OUT/failed.tsv" ] || die "passed.tsv or failed.tsv is missing"

# --- passed.tsv
# tiers come from the trusted checkout, never from the artifact. auto: merge and publish; review: open the
# PR and leave it for the owner (the merged version is then built and published as `unpublished`).
tiers=$(sed -e 's/#.*//' tools/update-tiers 2>/dev/null | awk 'NF')
badtier=$(awk 'NF != 2 || $2 !~ /^(auto|review|manual)$/ || seen[$1]++' <<<"$tiers")
[ -z "$badtier" ] || die "bad line in tools/update-tiers (malformed or duplicate): $badtier"
never=$(list_names tools/never-publish)
tier_of() { awk -v p="$1" '$1 == p { print $2 }' <<<"$tiers"; }
declare -A STATUS VERREV ALLOWED
# fields are split by hand: `read` with a tab IFS collapses empty fields, so a line could be accepted
# that no other parser would read the same way
tabs() { local t=${1//[!$'\t']/}; echo ${#t}; }
while IFS= read -r line; do
	[ -n "$line" ] || continue
	[ "$(tabs "$line")" -eq 2 ] || die "malformed line in passed.tsv: $line"
	status=${line%%$'\t'*}; rest=${line#*$'\t'}
	pkg=${rest%%$'\t'*}; verrev=${rest#*$'\t'}
	[ -n "$status" ] && [ -n "$pkg" ] && [ -n "$verrev" ] || die "malformed line in passed.tsv: $line"
	[ "$status" = bump ] || [ "$status" = unpublished ] || die "unknown status in passed.tsv: $status"
	[[ $pkg =~ $PKG_RE ]] || die "invalid package name in passed.tsv: $pkg"
	[[ $verrev =~ $VERREV_RE ]] || die "invalid version in passed.tsv: $pkg"
	[ -z "${STATUS[$pkg]:-}" ] || die "duplicate entry in passed.tsv: $pkg"
	[ -f "srcpkgs/$pkg/template" ] && [ ! -L "srcpkgs/$pkg" ] || die "no template for $pkg in the repository"
	grep -qxF -- "$pkg" <<<"$never" && die "$pkg is on tools/never-publish"
	if [ "$status" = bump ]; then
		case $(tier_of "$pkg") in
		auto | review) ;;
		manual) die "$pkg is tier manual: CI never bumps it" ;;
		*) [ "$pkg" = "${INPUT_PKG:-}" ] || die "$pkg is not in the auto or review tier" ;;
		esac
	fi
	if [ "$status" = unpublished ]; then
		# nothing is bumped, so the build must be of the template that is on main: no other version
		mver=$(sed -n 's/^version=//p' "srcpkgs/$pkg/template" | head -n1 | tr -d "\"'")
		mrev=$(sed -n 's/^revision=//p' "srcpkgs/$pkg/template" | head -n1 | tr -d "\"'")
		[[ $mver =~ ^${VER_RE}$ ]] && [[ $mrev =~ ^[0-9]+$ ]] || die "cannot read the version of $pkg from its template"
		[ "$verrev" = "${mver}_${mrev}" ] || die "version $verrev of $pkg does not match the template (${mver}_${mrev})"
	fi
	STATUS[$pkg]=$status
	VERREV[$pkg]=$verrev
done < "$BUILD_OUT/passed.tsv"

for pkg in "${!STATUS[@]}"; do
	ALLOWED[$pkg]=$(allowed_names "$pkg" | grep -xE "$NAME_RE" || true)
done

# `unpublished` entries outside the auto and review tiers are only believed when they are a build dependency
# of something that is being published here: a compromised build job cannot claim arbitrary templates
need_closure=
for pkg in "${!STATUS[@]}"; do
	[ "${STATUS[$pkg]}" = unpublished ] || continue
	case $(tier_of "$pkg") in auto | review) continue ;; esac
	[ "$pkg" = "${INPUT_PKG:-}" ] || need_closure=1
done
if [ -n "$need_closure" ]; then
	seeds=()
	for pkg in "${!STATUS[@]}"; do
		case $(tier_of "$pkg") in auto | review) seeds+=("$pkg") ;; *) [ "$pkg" != "${INPUT_PKG:-}" ] || seeds+=("$pkg") ;; esac
	done
	closure=$(deps_closure "${seeds[@]}")
	for pkg in "${!STATUS[@]}"; do
		[ "${STATUS[$pkg]}" = unpublished ] || continue
		case $(tier_of "$pkg") in auto | review) continue ;; esac
		[ "$pkg" = "${INPUT_PKG:-}" ] && continue
		grep -qxF -- "$pkg" <<<"$closure" || die "$pkg is not a build dependency of a package being published"
	done
fi

# --- packages
declare -A OWNER
shopt -s nullglob
for f in "$BUILD_OUT"/xbps/*.xbps; do
	b=${f##*/}
	[[ $b =~ ^(.+)-(${VER_RE}_[0-9]+)\.(x86_64|noarch)\.xbps$ ]] || die "invalid package file name: $b"
	name=${BASH_REMATCH[1]}
	vr=${BASH_REMATCH[2]}
	owner=
	for pkg in "${!STATUS[@]}"; do
		if [ "${VERREV[$pkg]}" = "$vr" ] && grep -qxF "$name" <<<"${ALLOWED[$pkg]}"; then owner=$pkg; break; fi
	done
	[ -n "$owner" ] || die "unexpected package in the build artifact: $b"
	OWNER[$b]=$owner
done
shopt -u nullglob

# --- package metadata: xbps-rindex indexes a package by what is inside it, not by its file name, so
# index the files in a scratch repository and read the metadata back with xbps itself. A file whose
# metadata disagrees with its name aborts (the artifact is not what it claims); a package whose provides,
# replaces, sonames... are not accounted for by its template or its files rejects that template only.
CHK=$(mktemp -d)
trap 'rm -rf "$CHK" "$CHK".*' EXIT
# who owns a soname: Void's common/shlibs, then ours (the build job has both in .upstream/)
UPSTREAM_SHLIBS=${VOIDLAB_UPSTREAM_SHLIBS:-}
if [ -z "$UPSTREAM_SHLIBS" ]; then
	UPSTREAM_SHLIBS=$CHK.shlibs
	curl -fsSL --retry 3 -o "$UPSTREAM_SHLIBS" https://raw.githubusercontent.com/void-linux/void-packages/master/common/shlibs ||
		die "cannot fetch Void's common/shlibs"
fi
[ -s "$UPSTREAM_SHLIBS" ] || die "Void's common/shlibs is empty"
declare -A SO_OWNER=() NEEDS=()
verify_metadata() {
	local f b name vr arch owner problems
	[ ${#OWNER[@]} -gt 0 ] || return 0
	cp "$BUILD_OUT"/xbps/*.xbps "$CHK"/
	XBPS_ARCH=x86_64 xbps-rindex -a "$CHK"/*.xbps >/dev/null 2>&1 || die "a package in the build artifact cannot be indexed"
	for f in "$CHK"/*.xbps; do
		b=${f##*/}
		[[ $b =~ ^(.+)-(${VER_RE}_[0-9]+)\.(x86_64|noarch)\.xbps$ ]] || die "invalid package file name: $b"
		name=${BASH_REMATCH[1]} vr=${BASH_REMATCH[2]} arch=${BASH_REMATCH[3]}
		[ "$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$CHK" -p pkgver "$name" 2>/dev/null)" = "$name-$vr" ] ||
			die "package metadata of $b does not match its file name"
		[ "$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$CHK" -p architecture "$name" 2>/dev/null)" = "$arch" ] ||
			die "package metadata of $b does not match its file name (architecture)"
		owner=${OWNER[$b]}
		problems=$(pkg_meta_problems "$CHK" "$b" "$owner" "$UPSTREAM_SHLIBS" common/shlibs)
		[ -z "$problems" ] || reject "$owner" "$problems"
		while IFS= read -r so; do [ -z "$so" ] || SO_OWNER[$so]=$owner; done < <(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$CHK" -p shlib-provides "$name" 2>/dev/null)
		# what it needs: package names (run_depends without the version) and sonames (shlib-requires)
		NEEDS[$b]=$( { XBPS_ARCH=x86_64 xbps-query -i -R --repository="$CHK" -p run_depends "$name" 2>/dev/null | sed -E 's/[<>=].*$//; s/-[^-]+_[0-9]+$//'
			XBPS_ARCH=x86_64 xbps-query -i -R --repository="$CHK" -p shlib-requires "$name" 2>/dev/null; } | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' || true)
	done
}
verify_metadata

# --- templates: only the version, revision and checksum lines may change
change_ok_re="^[<>] (version=${VER_RE}|revision=[0-9]+|checksum=\"?${HASH_RE}( ${HASH_RE})*\"?)\$"
change_cont_re="^[<>][[:space:]]+\"?${HASH_RE}( ${HASH_RE})*\"?\$"
for t in "$BUILD_OUT"/templates/*/; do
	[ -d "$t" ] || continue
	pkg=${t%/}; pkg=${pkg##*/}
	[ "${STATUS[$pkg]:-}" = bump ] || die "template in the build artifact for a package that was not bumped: $pkg"
done
for pkg in "${!STATUS[@]}"; do
	[ "${STATUS[$pkg]}" = bump ] || continue
	a=$BUILD_OUT/templates/$pkg/template
	[ -f "$a" ] || { reject "$pkg" "no bumped template for $pkg"; continue; }
	# diff prints "Binary files differ" and no change lines for a file with a NUL byte, and bash reads
	# straight through NUL and CR: neither may exist, or the diff below would validate nothing
	tr -d '\0' < "$a" | cmp -s - "$a" || { reject "$pkg" "template of $pkg contains NUL bytes"; continue; }
	if grep -q $'\r' "$a"; then reject "$pkg" "template of $pkg contains a carriage return"; continue; fi
	while IFS= read -r line; do
		[[ $line =~ $change_ok_re ]] || [[ $line =~ $change_cont_re ]] || { reject "$pkg" "template of $pkg changes more than version, revision and checksum: $line"; continue 2; }
	done < <(diff -a "srcpkgs/$pkg/template" "$a" | grep -E '^[<>]' || true)
	grep -qx "version=${VERREV[$pkg]%_*}" "$a" || { reject "$pkg" "template of $pkg does not carry version ${VERREV[$pkg]%_*}"; continue; }
	grep -qx 'revision=1' "$a" || { reject "$pkg" "template of $pkg does not have revision=1"; continue; }
	cmp -s "srcpkgs/$pkg/template" "$a" && reject "$pkg" "template of $pkg is unchanged"
done

# a template whose packages need a package of a rejected one from this run is rejected too: it was built
# against something that is not going to be published
name_map_load
changed=1
while [ -n "$changed" ]; do
	changed=
	for b in "${!OWNER[@]}"; do
		owner=${OWNER[$b]}
		[ -z "${REJECTED[$owner]:-}" ] || continue
		while IFS= read -r w; do
			[ -n "$w" ] || continue
			o=${SO_OWNER[$w]:-}
			[ -n "$o" ] || { o=$(owner_of "$w") && [ -n "${STATUS[$o]:-}" ]; } || continue
			if [ "$o" != "$owner" ] && [ -n "${REJECTED[$o]:-}" ]; then
				reject "$owner" "$b needs $w from $o, which is rejected"
				changed=1
				break
			fi
		done <<<"${NEEDS[$b]:-}"
	done
done

# --- failures: validated now, reported later
declare -A FAILED
while IFS= read -r line; do
	[ -n "$line" ] || continue
	[ "$(tabs "$line")" -eq 1 ] || die "malformed line in failed.tsv: $line"
	pkg=${line%%$'\t'*}; ver=${line#*$'\t'}
	[[ $pkg =~ $PKG_RE ]] && [[ $ver =~ ^${VER_RE}$ ]] || die "malformed line in failed.tsv: $line"
	FAILED[$pkg]=$ver
done < "$BUILD_OUT/failed.tsv"

report_issue() { # <kind> <pkg> <version> <intro> <text file>: untrusted text goes in as an indented block, mentions and backticks removed
	local kind=$1 pkg=$2 ver=$3 f=$5 body n=
	body=$(printf '%s\n\nRun: %s/%s/actions/runs/%s\n\n' \
		"$4" "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}")
	[ ! -f "$f" ] || body+=$(tail -n 40 "$f" | tr -cd '[:print:]\n' | tr -d '`@' | head -c 6000 | sed 's/^/    /')
	gh label create "auto-update-$kind" --color B60205 >/dev/null 2>&1 || true
	n=$(gh issue list --state open --label "auto-update-$kind" --search "\"auto-update $kind: $pkg\" in:title" \
		--json number --jq '.[0].number // empty' 2>/dev/null || true)
	if [ -n "$n" ]; then
		gh issue comment "$n" --body "$body" >/dev/null || true
	else
		gh issue create --title "auto-update $kind: $pkg $ver" --label "auto-update-$kind" --body "$body" >/dev/null || true
	fi
}
report_failure() { # <pkg> <version>
	report_issue failed "$1" "$2" "The auto-update workflow could not build or test $1 $2." "$BUILD_OUT/logs/$1.log"
}
report_rejection() { # <pkg>: the reasons may quote package metadata, which is artifact data
	local f=$CHK.reason
	printf '%s' "${REJECTED[$1]}" > "$f"
	report_issue rejected "$1" "${VERREV[$1]:-}" "The auto-update workflow built $1 ${VERREV[$1]:-}, but did not publish it: the package does not pass the checks in tools/ci-publish.sh. Fix it on main; the next run builds and publishes it." "$f"
}

# --- everything validated; from here on the artifact is trusted only for what was checked
git config user.name voidlab-bot
git config user.email voidlab-bot@users.noreply.github.com

for pkg in "${!FAILED[@]}"; do
	report_failure "$pkg" "${FAILED[$pkg]}"
done
declare -A SKIP=()
for pkg in "${!REJECTED[@]}"; do
	report_rejection "$pkg"
	SKIP[$pkg]=1
done
# the run still ends with an error when anything was rejected, after the rest is published
finish() { [ ${#REJECTED[@]} -eq 0 ] || die "rejected: ${!REJECTED[*]}"; exit 0; }

if [ ${#STATUS[@]} -eq 0 ]; then
	log "nothing to publish"
	finish
fi
[ -n "${VOIDLAB_PRIVKEY:-}" ] || die "no VOIDLAB_PRIVKEY, cannot publish: ${!STATUS[*]}"

for pkg in "${!STATUS[@]}"; do
	[ "${STATUS[$pkg]}" = bump ] || continue
	[ -z "${SKIP[$pkg]:-}" ] || continue
	ver=${VERREV[$pkg]%_*}
	branch=autobump/$pkg-$ver
	git fetch -q origin "$BASE" </dev/null && git switch -q "$BASE" && git reset -q --hard "origin/$BASE" ||
		{ log "cannot reset to origin/$BASE"; SKIP[$pkg]=1; continue; }
	# one open bump PR per package: a build job that proposes a new version every night cannot pile them up
	open_prs=$(gh pr list --state open --json headRefName \
		--jq "[.[] | select(.headRefName | startswith(\"autobump/$pkg-\"))] | length" </dev/null 2>/dev/null || echo 0)
	if [ "${open_prs:-0}" -gt 0 ] 2>/dev/null; then
		log "$pkg already has an open bump PR: skipping"
		SKIP[$pkg]=1
		continue
	fi
	if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
		log "$branch already exists, skipping $pkg"
		SKIP[$pkg]=1
		continue
	fi
	cp "$BUILD_OUT/templates/$pkg/template" "srcpkgs/$pkg/template"
	if ! { git switch -q -c "$branch" && git add "srcpkgs/$pkg/template" && git commit -q -m "$pkg $ver" &&
		git push -q origin "$branch"; } </dev/null; then
		log "could not push $branch"
		SKIP[$pkg]=1
		continue
	fi
	# only tier auto is merged by CI; review (and an unlisted package dispatched by hand) is built and tested,
	# then a human merges the PR and the next run publishes the merged version
	if [ "$(tier_of "$pkg")" = auto ]; then body="Bump $pkg to $ver. Built and tested by the auto-update workflow."
	else body="Bump $pkg to $ver. Built and tested by the auto-update workflow. Not merged automatically: merge it and the next daily run builds and publishes the merged version."; fi
	if ! gh pr create --base "$BASE" --head "$branch" --title "$pkg $ver" --body "$body" </dev/null >/dev/null; then
		# a pushed branch without a PR would make every later run skip this package
		log "could not open the PR for $pkg; removing $branch"
		git push -q origin --delete "$branch" </dev/null || true
		SKIP[$pkg]=1
		continue
	fi
	if [ "$(tier_of "$pkg")" != auto ]; then
		log "$pkg is not tier auto: PR left open"
		SKIP[$pkg]=1
		continue
	fi
	if ! gh pr merge "$branch" --squash --delete-branch --subject "$pkg $ver" --body "" </dev/null >/dev/null; then
		log "PR for $pkg did not merge; not publishing it"
		SKIP[$pkg]=1
	fi
done

"$VL" pull </dev/null || die "cannot pull the release"
# `unpublished` is the artifact's claim; verify it against the release. A version that is already published
# is never signed again from an artifact, so a compromised build job cannot swap the binaries of a package
# that has no merged-but-unreleased template.
shopt -s nullglob
for pkg in "${!STATUS[@]}"; do
	[ "${STATUS[$pkg]}" = unpublished ] || continue
	published=(repo/"$pkg-${VERREV[$pkg]}".*.xbps)
	if [ ${#published[@]} -gt 0 ]; then
		log "$pkg ${VERREV[$pkg]} is already published: ignoring the artifact"
		SKIP[$pkg]=1
	fi
done
shopt -u nullglob
accepted=()
shopt -s nullglob
for f in "$BUILD_OUT"/xbps/*.xbps; do
	b=${f##*/}
	[ -z "${SKIP[${OWNER[$b]}]:-}" ] || continue
	cp "$f" repo/
	accepted+=("repo/$b")
done
shopt -u nullglob
if [ ${#accepted[@]} -eq 0 ]; then
	log "nothing to publish"
	finish
fi
mapfile -t accepted < <(printf '%s\n' "${accepted[@]}" | sort -V) # oldest version last-wins order, see voidlab rindex_add
XBPS_ARCH=x86_64 xbps-rindex -f -a "${accepted[@]}" >/dev/null || die "cannot index the new packages"
XBPS_ARCH=x86_64 xbps-rindex -r repo >/dev/null

mkdir -p "$(dirname "$VOIDLAB_KEY")"
trap 'rm -f "$VOIDLAB_KEY"; rm -rf "$CHK" "$CHK".*' EXIT
(umask 077 && printf '%s\n' "$VOIDLAB_PRIVKEY" > "$VOIDLAB_KEY")
log "publishing ${#accepted[@]} packages"
"$VL" publish </dev/null || die "publish failed"
finish
