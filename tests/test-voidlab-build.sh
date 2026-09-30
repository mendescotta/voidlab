#!/usr/bin/env bash
# Build/index behavior with fake xbps-src and xbps-rindex (no real builds).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d)
cleanup() { [ -n "${BG:-}" ] && kill "$BG" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
BIN=$T/bin; mkdir -p "$BIN"
# fake xbps-rindex: log every invocation
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
# fake xbps-src: "pkg good*" drops a .xbps into <hostdir>/binpkgs, "pkg bad" fails,
# "sleep" just sleeps (to look like a running build)
cat > xbps-src <<'F'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in -H) H=$2; shift 2 ;; -m) shift 2 ;; *) break ;; esac; done
case "$1 $2" in
"pkg bad") exit 1 ;;
pkg\ *) mkdir -p "$H/binpkgs"; sleep 1; touch "$H/binpkgs/$2-1.0_1.x86_64.xbps" ;;
sleep*) sleep 30 ;;
esac
F
chmod +x xbps-src; git add -A; git commit -qm up

R=$T/root; mkdir -p "$R/srcpkgs/good"; cp "$HERE/../voidlab" "$R/"
tmpl good 2.0 1 > "$R/srcpkgs/good/template"
VOIDLAB_UPSTREAM_URL=$U VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync >/dev/null 2>&1

# Finding 2: a mid-list failure still indexes what succeeded
out=$("$R/voidlab" build good bad 2>&1 || true)
assert_grep "failure is reported" 'build failed: bad' <(echo "$out")
assert_file "successful build indexed despite later failure" "$R/repo/good-1.0_1.x86_64.xbps"

# Finding 3: files already indexed (and then pruned) are not copied again
rm -f "$R/repo/good-1.0_1.x86_64.xbps"
"$R/voidlab" build good2 >/dev/null 2>&1
assert_file "new build copied" "$R/repo/good2-1.0_1.x86_64.xbps"
assert_no  "old build not re-copied" "$R/repo/good-1.0_1.x86_64.xbps"

# Finding 1: status never touches .upstream; overlay/sync refuse during a build
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
