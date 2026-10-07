#!/usr/bin/env bash
# voidlab pull: seed repo/ and .release/ from the published release (gh shimmed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# release fixture: one package plus its repodata
mkdir -p "$T/fixture/root" "$T/empty" "$T/bin"
(cd "$T/fixture" && xbps-create -A noarch -n p-1.0_1 -s t "$T/empty" >/dev/null && XBPS_ARCH=x86_64 xbps-rindex -a p-1.0_1.noarch.xbps >/dev/null)
rmdir "$T/fixture/root"
cat > "$T/bin/gh" <<SHIM
#!/bin/sh
echo "\$*" >> "$T/gh.log"
[ "\$1 \$2" = "release download" ] || exit 1
while [ \$# -gt 0 ]; do [ "\$1" = -D ] && dir=\$2; shift; done
cp "$T/fixture"/* "\$dir"/
SHIM
chmod +x "$T/bin/gh"
export PATH=$T/bin:$PATH

R=$T/root; mkdir -p "$R"; cp "$HERE/../voidlab" "$R/"

out=$("$R/voidlab" pull 2>&1)
assert_grep "pull reports the count"             '^=> pulled 1 packages$' <(echo "$out")
assert_file "package lands in repo/"             "$R/repo/p-1.0_1.noarch.xbps"
assert_file "release repodata is kept for update" "$R/.release/x86_64-repodata"
assert_grep "gh is asked for the repo release"   'release download repo -R mendescotta/voidlab' "$T/gh.log"
got=$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$R/repo" -p pkgver p)
assert_eq   "repo/ is indexed with the pulled package" "$got" "p-1.0_1"

sum=$(sha256sum "$R/repo/p-1.0_1.noarch.xbps")
out=$("$R/voidlab" pull 2>&1)
assert_grep "second pull finds nothing new"      '^=> pulled 0 packages$' <(echo "$out")
assert_eq   "existing files are not overwritten" "$(sha256sum "$R/repo/p-1.0_1.noarch.xbps")" "$sum"

out=$(VOIDLAB_ARCH=x86_64-musl "$R/voidlab" pull 2>&1 || true)
assert_grep "musl is refused"                    'glibc-only' <(echo "$out")
rm -f "$T/fixture/x86_64-repodata"
out=$(VOIDLAB_GH_REPO=other/repo "$R/voidlab" pull 2>&1 || true)
assert_grep "a release without repodata is an error" 'no x86_64-repodata' <(echo "$out")
finish
