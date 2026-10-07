#!/usr/bin/env bash
# tools/ci-build.sh: the build half of auto-update. Read-only: it produces out/ (data) and never
# pushes, opens PRs or issues, publishes, or sees a signing key.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

W=$T/work; mkdir -p "$W/tools"; cd "$W"; git init -q
cp "$HERE/../tools/ci-build.sh" tools/ 2>/dev/null || true
for p in a b c z; do mkdir -p srcpkgs/$p; tmpl $p 1.0 1 > srcpkgs/$p/template; done
git add -A; git commit -qm init
# a pulled release package must be visible to xbps-src, which only reads hostdir/binpkgs
mkdir -p repo "$T/empty"
(cd repo && xbps-create -A noarch -n lib-1.0_1 -s t "$T/empty" >/dev/null && XBPS_ARCH=x86_64 xbps-rindex -a lib-1.0_1.noarch.xbps >/dev/null)

# stub voidlab: plan from $T/plan; build drops a fake package into repo/, fails for b
cat > "$T/vl" <<STUB
#!/bin/bash
echo "\$*" >> "$T/calls.log"
case \$1 in
update)
	if [ "\${2:-}" = --check ]; then cat "$T/plan"; exit 0; fi
	pkg=\$2; new=\$(awk -F'\t' -v p="\$pkg" '\$2 == p { print \$4 }' "$T/plan")
	sed -i "s/^version=.*/version=\$new/" "srcpkgs/\$pkg/template"
	printf 'bump\t%s\t1.0_1\t%s\n' "\$pkg" "\$new" ;;
build) echo "build \$2 sees: key=\${VOIDLAB_PRIVKEY:-none} token=\${GH_TOKEN:-none}" >> "$T/env.log"
	[ "\$2" != b ] || { echo "build log for b: compile error"; exit 1; }
	ver=\$(awk -F'\t' -v p="\$2" '\$2 == p { print (\$1 == "bump" ? \$4 "_1" : \$3) }' "$T/plan")
	echo x > "repo/\$2-\$ver.noarch.xbps" ;;
esac
exit 0
STUB
chmod +x "$T/vl"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\nexit 0\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH=$T/bin:$PATH VOIDLAB_BIN=$T/vl GH_TOKEN=gh-token-value VOIDLAB_PRIVKEY=PRIVATE-KEY-LINE1
run() { (cd "$W" && CI_AUTO_UPDATE_FORCE=1 AUTO_UPDATE_OUT=$W/out bash tools/ci-build.sh) 2>&1; }

out=$(cd "$W" && bash tools/ci-build.sh 2>&1 || true)
assert_grep "refuses to run outside GitHub Actions" 'refusing to run outside GitHub Actions' <(echo "$out")

printf 'bump\ta\t1.0_1\t1.1\nbump\tb\t1.0_1\t2.0\nunpublished\tc\t1.0_1\t0.9_1\nfail\td\t-\tno overlay template\ncurrent\te\t1.0_1\t-\n' > "$T/plan"
: > "$T/calls.log"; : > "$T/gh.log"
run >/dev/null
assert_grep "syncs"                              '^sync$' "$T/calls.log"
assert_grep "pulls the release"                  '^pull$' "$T/calls.log"
assert_file "release packages are seeded into hostdir/binpkgs" "$W/hostdir/binpkgs/lib-1.0_1.noarch.xbps"
assert_eq   "hostdir/binpkgs is indexed" "$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$W/hostdir/binpkgs" -p pkgver lib)" "lib-1.0_1"
assert_grep "a is built"                         '^build a$' "$T/calls.log"
assert_grep "a is tested"                        '^test a$'  "$T/calls.log"
assert_eq   "b is not tested after a failed build" "$(grep -c '^test b$' "$T/calls.log" || true)" "0"
assert_grep "unpublished c is built and tested"  '^test c$'  "$T/calls.log"
assert_eq   "failed detection d is never built"  "$(grep -c '^build d$' "$T/calls.log" || true)" "0"
assert_eq   "current e is never built"           "$(grep -c '^build e$' "$T/calls.log" || true)" "0"
assert_eq   "passed.tsv lists what passed, with the version built" "$(tr '\t\n' ' |' < "$W/out/passed.tsv")" "bump a 1.1_1|unpublished c 1.0_1|"
assert_eq   "failed.tsv lists what failed"       "$(tr '\t\n' ' |' < "$W/out/failed.tsv")" "b 2.0|"
assert_grep "the failing log is kept"            'compile error' "$W/out/logs/b.log"
assert_grep "a bumped template is handed over"   '^version=1.1$' "$W/out/templates/a/template"
assert_no   "no template for an unpublished package" "$W/out/templates/c"
assert_no   "no template for a failed package"   "$W/out/templates/b"
assert_file "new packages are collected"         "$W/out/xbps/a-1.1_1.noarch.xbps"
assert_file "unpublished packages are collected" "$W/out/xbps/c-1.0_1.noarch.xbps"
assert_no   "pulled packages are not re-collected" "$W/out/xbps/lib-1.0_1.noarch.xbps"
assert_no   "a failed build contributes nothing"  "$W/out/xbps/b-2.0_1.noarch.xbps"
assert_eq   "the work tree is reset between packages" "$(git -C "$W" status --short -- srcpkgs | wc -l)" "0"
assert_eq   "nothing is committed"               "$(git -C "$W" rev-list --count HEAD)" "1"
assert_eq   "gh is never asked for anything"     "$(wc -c < "$T/gh.log")" "0"
assert_grep "builds do not see the signing key"  'build a sees: key=none ' "$T/env.log"
assert_grep "builds do not see the GitHub token" 'token=none$' "$T/env.log"

# an explicit package is passed through, and the out dir is rebuilt from scratch
printf 'current\tz\t1.0_1\t-\n' > "$T/plan"; : > "$T/calls.log"
(cd "$W" && CI_AUTO_UPDATE_FORCE=1 AUTO_UPDATE_OUT=$W/out INPUT_PKG=z bash tools/ci-build.sh >/dev/null 2>&1)
assert_grep "INPUT_PKG is passed to update"      '^update --check z$' "$T/calls.log"
assert_eq   "nothing passed means an empty passed.tsv" "$(wc -c < "$W/out/passed.tsv")" "0"
assert_no   "stale output is removed"            "$W/out/templates/a"
finish
