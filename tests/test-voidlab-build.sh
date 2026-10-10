#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d)
cleanup() { [ -n "${BG:-}" ] && kill "$BG" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
BIN=$T/bin; mkdir -p "$BIN"
cat > "$BIN/xbps-rindex" <<'F'
#!/bin/sh
echo "$*" >> "$RINDEX_LOG"
F
chmod +x "$BIN/xbps-rindex"
export RINDEX_LOG=$T/rindex.log PATH=$BIN:$PATH

U=$T/upstream; mkdir -p "$U"; cd "$U"
git init -q -b master; git config user.email t@t; git config user.name t
mkdir -p srcpkgs/good srcpkgs/good2 srcpkgs/bad common
tmpl good 1.0 1 > srcpkgs/good/template; tmpl good2 1.0 1 > srcpkgs/good2/template
tmpl bad 1.0 1 > srcpkgs/bad/template; : > common/shlibs
cat > xbps-src <<'F'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in -H) H=$2; shift 2 ;; -m) shift 2 ;; *) break ;; esac; done
case "$1 $2" in
clean\ *) echo "$2" >> "$H/cleaned" ;;
"pkg bad") exit 1 ;;
pkg\ *) mkdir -p "$H/binpkgs"; sleep 1; touch "$H/binpkgs/$2-1.0_1.x86_64.xbps" ;;
sleep*) sleep 30 ;;
esac
F
chmod +x xbps-src; git add -A; git commit -qm up

R=$T/root; mkdir -p "$R/srcpkgs/good"; cp "$HERE/../voidlab" "$R/"
tmpl good 2.0 1 > "$R/srcpkgs/good/template"
VOIDLAB_UPSTREAM_URL=$U VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync >/dev/null 2>&1

out=$("$R/voidlab" build good bad 2>&1 || true)
assert_grep "failure is reported" 'build failed: bad' <(echo "$out")
assert_file "successful build indexed despite later failure" "$R/repo/good-1.0_1.x86_64.xbps"

assert_grep "builddir cleaned before build" '^good$' "$R/hostdir/cleaned"

rm -f "$R/repo/good-1.0_1.x86_64.xbps"
"$R/voidlab" build good2 >/dev/null 2>&1
assert_file "new build copied" "$R/repo/good2-1.0_1.x86_64.xbps"
assert_no  "old build not re-copied" "$R/repo/good-1.0_1.x86_64.xbps"

# xbps-rindex -f keeps the LAST file of a package, so files must be passed oldest version first
# (a glob sorts _10 before _9, which indexed the older revision and then deleted the newer one)
touch "$R/repo/ord-1.0_9.x86_64.xbps" "$R/repo/ord-1.0_10.x86_64.xbps" "$R/repo/ord-1.0_2.x86_64.xbps"
: > "$RINDEX_LOG"
"$R/voidlab" build good2 >/dev/null 2>&1
line=$(grep -e '-f -a' "$RINDEX_LOG" | head -n1)
order=$(grep -o 'ord-1.0_[0-9]*' <<<"$line" | tr '\n' ' ')
assert_eq "files are indexed oldest revision first" "$order" "ord-1.0_2 ord-1.0_9 ord-1.0_10 "
rm -f "$R"/repo/ord-*

# a build supersedes every other version of that package in repo/, even one that sorts higher
# (dinit-void 0.1 reverts the pulled 0.99.25_4; indexed oldest first, 0.99.25 would win)
touch "$R/repo/good2-9.0_1.x86_64.xbps" "$R/repo/good2-devel-9.0_1.x86_64.xbps" "$R/repo/other-9.0_1.x86_64.xbps"
"$R/voidlab" build good2 >/dev/null 2>&1
assert_file "the new build is in repo/"               "$R/repo/good2-1.0_1.x86_64.xbps"
assert_no   "another version of the built package is dropped" "$R/repo/good2-9.0_1.x86_64.xbps"
assert_file "a package whose name merely starts the same stays" "$R/repo/good2-devel-9.0_1.x86_64.xbps"
assert_file "unrelated packages stay"                 "$R/repo/other-9.0_1.x86_64.xbps"
rm -f "$R"/repo/good2-devel-* "$R"/repo/other-*

"$R/voidlab" overlay
"$R/voidlab" status >/dev/null
assert_grep "status leaves the overlay in place" 'version=2.0' "$R/.upstream/srcpkgs/good/template"
(cd "$R/.upstream" && exec ./xbps-src sleep) & BG=$!
sleep 0.5
out=$("$R/voidlab" overlay 2>&1 || true)
assert_grep "overlay refuses while a build runs" 'another xbps-src build is running' <(echo "$out")
out=$(VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync 2>&1 || true)
assert_grep "sync refuses while a build runs" 'another xbps-src build is running' <(echo "$out")
"$R/voidlab" status >/dev/null && ok "status still works during a build" || fail "status failed during a build"
finish
