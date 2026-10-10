#!/usr/bin/env bash
# voidlab update: stable-version detection, template bump, release-gap detection.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'
ttmpl() { tmpl "$@"; echo "checksum=old"; }

# fake upstream: a stub xbps-src whose update-check answers from uc/<pkg>
U=$T/upstream; mkdir -p "$U/uc" "$U/srcpkgs"; cd "$U"
git init -q -b master; git config user.email t@t; git config user.name t
cat > xbps-src <<'EOF'
#!/bin/sh
case $1 in
update-check) cat "$(dirname "$0")/uc/$2" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
chmod +x xbps-src
printf 'a-1.0 -> a-1.1\na-1.0 -> a-1.2\na-1.0 -> a-1.3rc1\na-1.0 -> a-1.3.beta2\na-1.0 -> a-1.10\n' > uc/a
: > uc/b
printf 'c-1.0 -> c-1.1rc1\nc-1.0 -> c-1.1-alpha\n' > uc/c
printf 'xbps-src: update-check: could not determine the upstream version\n' > uc/e
printf 'f-1.0 -> f-1.1\n' > uc/f
printf 'n-1.0 -> n-1.5\n' > uc/n
# upstream tag names are attacker-controlled: shell and sed metacharacters must never reach a template
printf 'v-1.0 -> v-1.2\nv-1.0 -> v-9.9$(touch /tmp/pwned-voidlab)\nv-1.0 -> v-9.8;rm\nv-1.0 -> v-9.7/y\nv-1.0 -> v-9.6&\nv-1.0 -> v-9.5`id`\nv-1.0 -> v-9.4\\x\n' > uc/v
printf 'm-1.0 -> m-9.9$(id)\nm-1.0 -> m-9.8;x\n' > uc/m
touch srcpkgs/.keep; git add -A; git commit -qm up

# fake root: overlay templates, allowlist of a b c d e f (d has no template)
R=$T/root; mkdir -p "$R/tools"; cp "$HERE/../voidlab" "$R/"
for p in a c e f n v m; do mkdir -p "$R/srcpkgs/$p"; ttmpl $p 1.0 1 > "$R/srcpkgs/$p/template"; done
mkdir -p "$R/srcpkgs/b"; ttmpl b 2.0 1 > "$R/srcpkgs/b/template"
printf '# tiers\na auto\nb auto  # leaf\nc auto\nd auto\ne auto\nf review\nm manual\n' > "$R/tools/update-tiers"
VOIDLAB_UPSTREAM_URL=$U VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync >/dev/null

printf '#!/bin/sh\nsed -i "s/^checksum=.*/checksum=deadbeef/" "$1"\n' > "$T/gensum"
printf '#!/bin/sh\nexit 1\n' > "$T/gensum-fail"
chmod +x "$T/gensum" "$T/gensum-fail"

out=$("$R/voidlab" update --check)
assert_grep "a: highest stable by sort -V (1.10, not 1.3rc1 or 1.2)" "^bump${tab}a${tab}1.0_1${tab}1.10\$" <(echo "$out")
assert_grep "b: no update is current"            "^current${tab}b${tab}2.0_1" <(echo "$out")
assert_grep "c: only pre-releases is current"    "^current${tab}c${tab}1.0_1" <(echo "$out")
assert_grep "d: listed without a template fails" "^fail${tab}d${tab}-${tab}no overlay template" <(echo "$out")
assert_grep "e: error text without -> is current" "^current${tab}e${tab}1.0_1" <(echo "$out")
assert_eq   "n: unlisted (notify) is not listed" "$(grep -c "${tab}n${tab}" <<<"$out" || true)" "0"
assert_grep "--check leaves the template alone"  '^version=1.0$' "$R/srcpkgs/a/template"

out=$(VOIDLAB_GENSUM=$T/gensum "$R/voidlab" update a)
assert_grep "update a reports the bump"          "^bump${tab}a${tab}1.0_1${tab}1.10\$" <(echo "$out")
assert_grep "bump rewrites version"              '^version=1.10$'       "$R/srcpkgs/a/template"
assert_grep "bump resets revision"               '^revision=1$'         "$R/srcpkgs/a/template"
assert_grep "bump regenerates the checksum"      '^checksum=deadbeef$'  "$R/srcpkgs/a/template"
assert_grep "other templates are untouched"      '^version=2.0$'        "$R/srcpkgs/b/template"

rev=$(printf 'pkgname=a\nversion=1.0\nrevision=4\nchecksum=old\n'); printf '%s\n' "$rev" > "$R/srcpkgs/a/template"
VOIDLAB_GENSUM=$T/gensum "$R/voidlab" update a >/dev/null
assert_grep "bump resets a higher revision to 1" '^revision=1$' "$R/srcpkgs/a/template"

out=$(VOIDLAB_GENSUM=$T/gensum-fail "$R/voidlab" update f)
assert_grep "failed checksum reports fail"       "^fail${tab}f${tab}1.0_1${tab}checksum" <(echo "$out")
assert_grep "failed checksum restores version"   '^version=1.0$'    "$R/srcpkgs/f/template"
assert_grep "failed checksum restores checksum"  '^checksum=old$'   "$R/srcpkgs/f/template"

out=$(VOIDLAB_GENSUM=$T/gensum "$R/voidlab" update v m)
assert_grep "malicious tags are ignored, the legitimate version wins" "^bump${tab}v${tab}1.0_1${tab}1.2\$" <(echo "$out")
assert_grep "only malicious tags means current"  "^current${tab}m${tab}1.0_1" <(echo "$out")
assert_grep "the template gets exactly the clean version" '^version=1.2$' "$R/srcpkgs/v/template"
assert_eq   "no metacharacter reached any template" "$(cat "$R/srcpkgs/v/template" "$R/srcpkgs/m/template" | grep -cE '[$;&`\\/]' || true)" "0"
assert_eq   "no injected command ran"            "$([ -e /tmp/pwned-voidlab ] && echo ran || echo none)" "none"
assert_grep "m template untouched"               '^version=1.0$' "$R/srcpkgs/m/template"

out=$("$R/voidlab" update --all)
assert_eq   "--all lists every overlay template" "$(grep -c . <<<"$out")" "8"
assert_grep "--all includes packages off the allowlist" "^bump${tab}n${tab}1.0_1${tab}1.5\$" <(echo "$out")
assert_grep "--all never rewrites templates"     '^version=1.0$' "$R/srcpkgs/n/template"

# release index: b-1.0_1 and c-1.0_1 published
mkdir -p "$T/rel/root" "$R/.release"
(cd "$T/rel" && for pv in b-1.0_1 c-1.0_1; do
	xbps-create -A noarch -n $pv -s t root >/dev/null
	XBPS_ARCH=x86_64 xbps-rindex -a $pv.noarch.xbps >/dev/null
done)
cp "$T/rel/x86_64-repodata" "$R/.release/"
printf 'pkgname=c\nversion=1.0\nrevision=1\nchecksum=old\n' > "$R/srcpkgs/c/template"
out=$("$R/voidlab" update --check b c e)
assert_grep "b: template newer than release is unpublished" "^unpublished${tab}b${tab}2.0_1${tab}1.0_1\$" <(echo "$out")
assert_grep "c: same as release is current"      "^current${tab}c${tab}1.0_1" <(echo "$out")
assert_grep "e: absent from release is unpublished" "^unpublished${tab}e${tab}1.0_1${tab}-\$" <(echo "$out")
# a lower version that reverts the released one (dinit-void 0.99.25 -> 0.1) is newer, as for xbps
printf 'pkgname=c\nreverts="0.9_1 1.0_1"\nversion=0.1\nrevision=1\nchecksum=old\n' > "$R/srcpkgs/c/template"
out=$("$R/voidlab" update --check c)
assert_grep "c: reverting the released version is unpublished" "^unpublished${tab}c${tab}0.1_1${tab}1.0_1\$" <(echo "$out")
printf 'pkgname=c\nversion=0.1\nrevision=1\nchecksum=old\n' > "$R/srcpkgs/c/template"
out=$("$R/voidlab" update --check c)
assert_grep "c: older without reverts stays current" "^current${tab}c${tab}0.1_1" <(echo "$out")
finish
