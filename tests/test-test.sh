#!/usr/bin/env bash
# voidlab test: built version matches the template, dependencies and shared libs resolve.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

R=$T/root; mkdir -p "$R"; cp "$HERE/../voidlab" "$R/"
for p in p bad stale nobuilt; do mkdir -p "$R/srcpkgs/$p"; tmpl $p 1.0 1 > "$R/srcpkgs/$p/template"; done

mkpkg() { # <dir> <pkgver> [xbps-create args...]
	local d=$1 pv=$2; shift 2
	mkdir -p "$d" "$T/empty"
	(cd "$d" && xbps-create -A noarch -n "$pv" -s t "$@" "$T/empty" >/dev/null && XBPS_ARCH=x86_64 xbps-rindex -a "$pv.noarch.xbps" >/dev/null)
}
mkpkg "$R/repo" p-1.0_1 -D "q>=1"
mkpkg "$R/repo" bad-1.0_1 -D "missing>=1"
mkpkg "$R/repo" stale-0.9_1
mkpkg "$T/official" q-1.0_1
export VOIDLAB_OFFICIAL_URL=$T/official

out=$("$R/voidlab" test p 2>&1) && rc=0 || rc=$?
assert_grep "p resolves its dependency from official" '^ok p$' <(echo "$out")
assert_eq   "all-ok run exits 0" "$rc" "0"

out=$("$R/voidlab" test bad 2>&1) && rc=0 || rc=$?
assert_grep "unresolvable dependency fails"       '^FAIL bad: dry-run install failed' <(echo "$out")
assert_eq   "failing run exits 1" "$rc" "1"

out=$("$R/voidlab" test stale 2>&1 || true)
assert_grep "built version differing from the template fails" '^FAIL stale: built 0.9_1, template says 1.0_1' <(echo "$out")

out=$("$R/voidlab" test nobuilt 2>&1 || true)
assert_grep "package missing from repo fails"     '^FAIL nobuilt: not built' <(echo "$out")

out=$("$R/voidlab" test ghost 2>&1 || true)
assert_grep "package without a template fails"    '^FAIL ghost: no overlay template' <(echo "$out")

out=$("$R/voidlab" test bad p 2>&1) && rc=0 || rc=$?
assert_grep "one failure does not stop the next package" '^ok p$' <(echo "$out")
assert_eq   "mixed run exits 1" "$rc" "1"
# a remote official repo needs an index sync first; a directory repo does not, so serve one over HTTP
openssl genrsa -out "$T/key.pem" 2048 2>/dev/null
XBPS_ARCH=x86_64 xbps-rindex --privkey "$T/key.pem" --signedby test --sign "$T/official" >/dev/null
port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd "$T/official" && exec python3 -I -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
srv=$!
trap 'kill $srv 2>/dev/null || true; rm -rf "$T"' EXIT
until curl -sf "http://127.0.0.1:$port/x86_64-repodata" -o /dev/null; do sleep 0.2; done
out=$(VOIDLAB_OFFICIAL_URL=http://127.0.0.1:$port "$R/voidlab" test p 2>&1 || true)
assert_grep "remote official repo is synced before the dry run" '^ok p$' <(echo "$out")

out=$("$R/voidlab" test 2>&1 || true)
assert_grep "no arguments prints usage"           'usage: voidlab test' <(echo "$out")
finish
