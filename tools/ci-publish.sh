#!/usr/bin/env bash
# Publish half of .github/workflows/auto-update.yml (job `publish`): the only place with a write token
# and the signing key. It never runs anything from the build job: $BUILD_OUT (the downloaded artifact)
# is untrusted DATA, validated strictly before anything is pushed, merged or signed. Any deviation
# aborts the whole run:
#   - only these files, no symlinks: passed.tsv failed.tsv templates/<n>/template xbps/<n>.xbps logs/<n>.log
#   - passed.tsv: `bump|unpublished<TAB>pkg<TAB>version_revision`, pkg on the allowlist (or INPUT_PKG)
#   - a bumped template may differ from main only in its version, revision and checksum lines
#   - a package file must be the passed package or one of its declared subpackages, at the passed version
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

VL=${VOIDLAB_BIN:-./voidlab}
BASE=${BASE_BRANCH:-main}
BUILD_OUT=${BUILD_OUT:-}
export VOIDLAB_KEY=${VOIDLAB_KEY:-$HOME/.config/voidlab/privkey.pem}
export GH_REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}
[ -n "$BUILD_OUT" ] && [ -d "$BUILD_OUT" ] || die "BUILD_OUT must be the downloaded build artifact directory"

NAME_RE='[A-Za-z0-9][A-Za-z0-9._+~-]*'
PKG_RE='^[a-z0-9][a-z0-9._+-]*$'
VER_RE='[0-9][0-9A-Za-z.+~]*'
VERREV_RE="^${VER_RE}_[0-9]+\$"
HASH_RE='[0-9a-f]{64}'

[ -z "${INPUT_PKG:-}" ] || [[ $INPUT_PKG =~ $PKG_RE ]] || die "invalid INPUT_PKG"

# --- layout: only the expected files, no links, no special files
if find "$BUILD_OUT" -type l | grep -q .; then die "symlink in the build artifact"; fi
if find "$BUILD_OUT" ! -type f ! -type d | grep -q .; then die "special file in the build artifact"; fi
layout_re="^(passed\.tsv|failed\.tsv|templates/$NAME_RE/template|xbps/$NAME_RE\.xbps|logs/$NAME_RE\.log)\$"
while IFS= read -r f; do
	rel=${f#"$BUILD_OUT"/}
	[[ $rel =~ $layout_re ]] || die "unexpected file in the build artifact: $rel"
done < <(find "$BUILD_OUT" -type f)
[ -f "$BUILD_OUT/passed.tsv" ] && [ -f "$BUILD_OUT/failed.tsv" ] || die "passed.tsv or failed.tsv is missing"

# --- passed.tsv
allow=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' tools/auto-update.allow 2>/dev/null | awk 'NF')
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
	if ! grep -qxF "$pkg" <<<"$allow" && [ "$pkg" != "${INPUT_PKG:-}" ]; then die "$pkg is not on the allowlist"; fi
	STATUS[$pkg]=$status
	VERREV[$pkg]=$verrev
done < "$BUILD_OUT/passed.tsv"

# names a package may legitimately produce: itself, subpackages declared in the template (text only,
# nothing is executed) and symlinked subpackage directories
allowed_names() {
	local pkg=$1 t=srcpkgs/$1/template w l
	echo "$pkg"
	sed -n 's/^\([A-Za-z0-9._+-][A-Za-z0-9._+-]*\)_package[[:space:]]*(.*/\1/p' "$t"
	perl -0ne 'print "$1\n" if /^subpackages=["\x27]?([^"\x27]*)["\x27]?/m' "$t" | tr -s ' \t\n' '\n\n\n' |
		sed -e "s/\${pkgname}/$pkg/g" -e "s/\$pkgname/$pkg/g"
	for l in srcpkgs/*; do
		[ -L "$l" ] && [ "$(readlink "$l")" = "$pkg" ] && echo "${l##*/}"
	done
}
for pkg in "${!STATUS[@]}"; do
	ALLOWED[$pkg]=$(allowed_names "$pkg" | grep -xE "$NAME_RE" || true)
done

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
# index the files in a scratch repository and read the metadata back with xbps itself
verify_metadata() {
	local chk f b name vr arch owner key v so
	[ ${#OWNER[@]} -gt 0 ] || return 0
	chk=$(mktemp -d)
	cp "$BUILD_OUT"/xbps/*.xbps "$chk"/
	XBPS_ARCH=x86_64 xbps-rindex -a "$chk"/*.xbps >/dev/null 2>&1 || die "a package in the build artifact cannot be indexed"
	for f in "$chk"/*.xbps; do
		b=${f##*/}
		[[ $b =~ ^(.+)-(${VER_RE}_[0-9]+)\.(x86_64|noarch)\.xbps$ ]] || die "invalid package file name: $b"
		name=${BASH_REMATCH[1]} vr=${BASH_REMATCH[2]} arch=${BASH_REMATCH[3]}
		meta() { XBPS_ARCH=x86_64 xbps-query -i -R --repository="$chk" -p "$1" "$name" 2>/dev/null; }
		[ "$(meta pkgver)" = "$name-$vr" ] || die "package metadata of $b does not match its file name"
		[ "$(meta architecture)" = "$arch" ] || die "package metadata of $b does not match its file name (architecture)"
		owner=${OWNER[$b]}
		# anything that can change what other packages resolve to must come from the template itself
		for key in provides replaces reverts conflicts alternatives; do
			while IFS= read -r v; do
				[ -n "$v" ] || continue
				grep -qF -- "$v" "srcpkgs/$owner/template" || die "$b declares $key $v, which the template of $owner does not"
			done < <(meta "$key")
		done
		while IFS= read -r so; do
			[ -n "$so" ] || continue
			[[ $so == *"$owner"* || $so == *"${owner#lib}"* ]] || die "$b has shlib-provides $so, which does not belong to $owner"
		done < <(meta shlib-provides)
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
	[ -f "$a" ] || die "no bumped template for $pkg"
	# diff prints "Binary files differ" and no change lines for a file with a NUL byte, and bash reads
	# straight through NUL and CR: neither may exist, or the diff below would validate nothing
	tr -d '\0' < "$a" | cmp -s - "$a" || die "template of $pkg contains NUL bytes"
	if grep -q $'\r' "$a"; then die "template of $pkg contains a carriage return"; fi
	while IFS= read -r line; do
		[[ $line =~ $change_ok_re ]] || [[ $line =~ $change_cont_re ]] || die "template of $pkg changes more than version, revision and checksum: $line"
	done < <(diff -a "srcpkgs/$pkg/template" "$a" | grep -E '^[<>]' || true)
	grep -qx "version=${VERREV[$pkg]%_*}" "$a" || die "template of $pkg does not carry version ${VERREV[$pkg]%_*}"
	grep -qx 'revision=1' "$a" || die "template of $pkg does not have revision=1"
	cmp -s "srcpkgs/$pkg/template" "$a" && die "template of $pkg is unchanged"
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

report_failure() { # <pkg> <version>: untrusted log text goes in as an indented block, mentions and backticks removed
	local pkg=$1 ver=$2 f=$BUILD_OUT/logs/$1.log body n=
	body=$(printf 'The auto-update workflow could not build or test %s %s.\n\nRun: %s/%s/actions/runs/%s\n\n' \
		"$pkg" "$ver" "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}")
	[ ! -f "$f" ] || body+=$(tail -n 40 "$f" | tr -cd '[:print:]\n' | tr -d '`@' | head -c 6000 | sed 's/^/    /')
	gh label create auto-update-failed --color B60205 >/dev/null 2>&1 || true
	n=$(gh issue list --state open --label auto-update-failed --search "\"auto-update failed: $pkg\" in:title" \
		--json number --jq '.[0].number // empty' 2>/dev/null || true)
	if [ -n "$n" ]; then
		gh issue comment "$n" --body "$body" >/dev/null || true
	else
		gh issue create --title "auto-update failed: $pkg $ver" --label auto-update-failed --body "$body" >/dev/null || true
	fi
}

# --- everything validated; from here on the artifact is trusted only for what was checked
git config user.name voidlab-bot
git config user.email voidlab-bot@users.noreply.github.com

for pkg in "${!FAILED[@]}"; do
	report_failure "$pkg" "${FAILED[$pkg]}"
done

if [ ${#STATUS[@]} -eq 0 ]; then
	log "nothing to publish"
	exit 0
fi
[ -n "${VOIDLAB_PRIVKEY:-}" ] || die "no VOIDLAB_PRIVKEY, cannot publish: ${!STATUS[*]}"

declare -A SKIP
for pkg in "${!STATUS[@]}"; do
	[ "${STATUS[$pkg]}" = bump ] || continue
	ver=${VERREV[$pkg]%_*}
	branch=autobump/$pkg-$ver
	git fetch -q origin "$BASE" </dev/null && git switch -q "$BASE" && git reset -q --hard "origin/$BASE" ||
		{ log "cannot reset to origin/$BASE"; SKIP[$pkg]=1; continue; }
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
	if ! gh pr create --base "$BASE" --head "$branch" --title "$pkg $ver" \
			--body "Bump $pkg to $ver. Built and tested by the auto-update workflow." </dev/null >/dev/null ||
		! gh pr merge "$branch" --squash --delete-branch --subject "$pkg $ver" --body "" </dev/null >/dev/null; then
		log "PR for $pkg did not merge; not publishing it"
		SKIP[$pkg]=1
	fi
done

"$VL" pull </dev/null || die "cannot pull the release"
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
	exit 0
fi
XBPS_ARCH=x86_64 xbps-rindex -f -a "${accepted[@]}" >/dev/null || die "cannot index the new packages"
XBPS_ARCH=x86_64 xbps-rindex -r repo >/dev/null

mkdir -p "$(dirname "$VOIDLAB_KEY")"
trap 'rm -f "$VOIDLAB_KEY"' EXIT
(umask 077 && printf '%s\n' "$VOIDLAB_PRIVKEY" > "$VOIDLAB_KEY")
log "publishing ${#accepted[@]} packages"
"$VL" publish </dev/null
