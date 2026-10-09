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
cp "$HERE/../tools/ci-build.sh" "$HERE/../tools/ci-lib.sh" tools/ 2>/dev/null || true
for p in a b c z dep nv; do mkdir -p srcpkgs/$p; tmpl $p 1.0 1 > srcpkgs/$p/template; done
printf "# never\nnv\n" > tools/never-publish
git add -A; git commit -qm init
# a pulled release package must be visible to xbps-src, which only reads hostdir/binpkgs
mkdir -p repo "$T/empty"
(cd repo && xbps-create -A noarch -n lib-1.0_1 -s t "$T/empty" >/dev/null && xbps-create -A noarch -n a-1.0_1 -s t "$T/empty" >/dev/null && XBPS_ARCH=x86_64 xbps-rindex -a lib-1.0_1.noarch.xbps a-1.0_1.noarch.xbps >/dev/null)

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
	echo x > "repo/\$2-\$ver.noarch.xbps"
	# a real package whose metadata the publish job would reject
	if [ -f "$T/badmeta" ] && [ "\$2" = a ]; then rm -f "repo/a-\$ver.noarch.xbps"; (cd repo && xbps-create -q -A noarch -n "a-\$ver" -s t -P "glibc-9999_1" "$T/empty" >/dev/null && XBPS_ARCH=x86_64 xbps-rindex -a "a-\$ver.noarch.xbps" >/dev/null); fi
	# a build that also had to build dependencies of other overlay templates
	if [ -f "$T/deps" ] && [ "\$2" = a ]; then echo x > repo/dep-1.0_1.noarch.xbps; echo x > repo/nv-1.0_1.noarch.xbps; echo x > repo/zzz-1.0_1.noarch.xbps; fi ;;
esac
exit 0
STUB
chmod +x "$T/vl"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >> "%s/gh.log"\nexit 0\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH=$T/bin:$PATH VOIDLAB_BIN=$T/vl GH_TOKEN=gh-token-value VOIDLAB_PRIVKEY=PRIVATE-KEY-LINE1
run() { (cd "$W" && CI_AUTO_UPDATE_FORCE=1 AUTO_UPDATE_OUT=$W/out AUTO_UPDATE_SUMMARY=$T/summary.md bash tools/ci-build.sh) 2>&1; }

out=$(cd "$W" && env -u GITHUB_ACTIONS bash tools/ci-build.sh 2>&1 || true)
assert_grep "refuses to run outside GitHub Actions" 'refusing to run outside GitHub Actions' <(echo "$out")

printf 'bump\ta\t1.0_1\t1.1\nbump\tb\t1.0_1\t2.0\nunpublished\tc\t1.0_1\t0.9_1\nfail\td\t-\tno overlay template\ncurrent\te\t1.0_1\t-\n' > "$T/plan"
: > "$T/calls.log"; : > "$T/gh.log"
run >/dev/null
assert_grep "syncs"                              '^sync$' "$T/calls.log"
assert_grep "pulls the release"                  '^pull$' "$T/calls.log"
assert_file "release packages are seeded into hostdir/binpkgs" "$W/hostdir/binpkgs/a-1.0_1.noarch.xbps"
assert_eq   "hostdir/binpkgs is indexed" "$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$W/hostdir/binpkgs" -p pkgver a)" "a-1.0_1"
assert_no   "a release package no template makes is not seeded (it would make xbps-src rebuild Void's package)" "$W/hostdir/binpkgs/lib-1.0_1.noarch.xbps"
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
assert_no   "pulled packages are not re-collected" "$W/out/xbps/dep-1.0_1.noarch.xbps"
assert_no   "a failed build contributes nothing"  "$W/out/xbps/b-2.0_1.noarch.xbps"
assert_eq   "the work tree is reset between packages" "$(git -C "$W" status --short -- srcpkgs | wc -l)" "0"
assert_eq   "nothing is committed"               "$(git -C "$W" rev-list --count HEAD)" "1"
assert_eq   "gh is never asked for anything"     "$(wc -c < "$T/gh.log")" "0"
assert_grep "builds do not see the signing key"  'build a sees: key=none ' "$T/env.log"
assert_grep "builds do not see the GitHub token" 'token=none$' "$T/env.log"

assert_grep "summary lists every checked package" '^| bump | a | 1.0_1 | 1.1 |$' "$T/summary.md"
assert_grep "summary lists up-to-date packages"   '^| current | e | 1.0_1 | - |$' "$T/summary.md"
assert_grep "summary says what passed"            'Passed: a c' "$T/summary.md"
assert_grep "summary says what failed"            'Failed: b' "$T/summary.md"
assert_no   "the summary stays out of the artifact" "$W/out/summary.md"

# dependencies that had to be built along the way: owned by an overlay template -> `unpublished`
# entry of that owner; never-publish owners and unknown names are not trusted with an entry
printf 'bump\ta\t1.0_1\t1.1\n' > "$T/plan"; : > "$T/deps"
run >/dev/null
assert_grep "a dependency build becomes an unpublished entry of its owner" '^unpublished'"$tab"'dep'"$tab"'1.0_1$' "$W/out/passed.tsv"
assert_file "its package file is in the artifact"   "$W/out/xbps/dep-1.0_1.noarch.xbps"
assert_eq   "a never-publish owner gets no entry"   "$(grep -c "${tab}nv${tab}" "$W/out/passed.tsv" || true)" "0"
assert_no   "and its package file is left out"      "$W/out/xbps/nv-1.0_1.noarch.xbps"
assert_eq   "an unknown package gets no entry"      "$(grep -c "zzz" "$W/out/passed.tsv" || true)" "0"
assert_no   "an unknown package file is not handed over (it would abort the publish run)" "$W/out/xbps/zzz-1.0_1.noarch.xbps"
# a dependency built at another version than its template on main is dropped, not passed on
echo x > /dev/null
assert_eq   "the built package itself is one entry" "$(grep -c "${tab}a${tab}" "$W/out/passed.tsv" || true)" "1"
# a package that was already recorded as someone's dependency and is then built on its own: one entry (the
# publish job rejects a duplicate and the whole run is lost)
printf 'bump\ta\t1.0_1\t1.1\nunpublished\tdep\t1.0_1\t0.9_1\n' > "$T/plan"
run >/dev/null
assert_eq   "a dependency that is also in the plan gets one entry" "$(grep -c "${tab}dep${tab}" "$W/out/passed.tsv" || true)" "1"
rm -f "$T/deps"

# a package that would be rejected by the publish job fails here, with the reason in its log
rm -f "$W/repo"/a-1.1_1.* "$W/repo"/c-1.0_1.*
printf 'bump\ta\t1.0_1\t1.1\nunpublished\tc\t1.0_1\t0.9_1\n' > "$T/plan"; : > "$T/badmeta"
out=$(run)
assert_eq   "a package failing the publish checks is a failure" "$(tr '\t\n' ' |' < "$W/out/failed.tsv")" "a 1.1|"
assert_grep "its log gives the reason"           'declares provides glibc-9999_1' "$W/out/logs/a.log"
assert_no   "its packages are not handed over"   "$W/out/xbps/a-1.1_1.noarch.xbps"
assert_eq   "the rest still passes"              "$(tr '\t\n' ' |' < "$W/out/passed.tsv")" "unpublished c 1.0_1|"
rm -f "$T/badmeta" "$W/repo"/a-1.1_1.*

# the time budget: nothing new is started after it, and that is logged
printf 'bump\ta\t1.0_1\t1.1\n' > "$T/plan"; : > "$T/calls.log"
out=$(cd "$W" && CI_AUTO_UPDATE_FORCE=1 AUTO_UPDATE_OUT=$W/out AUTO_UPDATE_BUDGET_MIN=0 bash tools/ci-build.sh 2>&1)
assert_eq   "no build starts after the budget"   "$(grep -c '^build ' "$T/calls.log" || true)" "0"
assert_grep "the skip is logged"                 'a is left for the next run' <(echo "$out")

# a bump whose autobump branch already exists on origin is not rebuilt
git init -q --bare "$T/origin.git"; git -C "$W" remote add origin "$T/origin.git"
git -C "$W" push -q origin HEAD:refs/heads/autobump/a-1.1
printf 'bump\ta\t1.0_1\t1.1\nbump\tb\t1.0_1\t2.0\n' > "$T/plan"; : > "$T/calls.log"
run >/dev/null
assert_eq   "an existing autobump branch is not rebuilt" "$(grep -c '^build a$' "$T/calls.log" || true)" "0"
assert_grep "other bumps are still built"        '^build b$' "$T/calls.log"
assert_eq   "nothing is pushed to origin"        "$(git -C "$T/origin.git" branch --list | wc -l)" "1"
git -C "$W" remote remove origin

# an explicit package is passed through, and the out dir is rebuilt from scratch
printf 'current\tz\t1.0_1\t-\n' > "$T/plan"; : > "$T/calls.log"
(cd "$W" && CI_AUTO_UPDATE_FORCE=1 AUTO_UPDATE_OUT=$W/out INPUT_PKG=z bash tools/ci-build.sh >/dev/null 2>&1)
assert_grep "INPUT_PKG is passed to update"      '^update --check z$' "$T/calls.log"
assert_eq   "nothing passed means an empty passed.tsv" "$(wc -c < "$W/out/passed.tsv")" "0"
assert_no   "stale output is removed"            "$W/out/templates/a"
finish
