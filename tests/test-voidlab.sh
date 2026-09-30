#!/usr/bin/env bash
# Exercises sync/overlay/status against a fake upstream repo (no xbps-src).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
U=$T/upstream; mkdir -p "$U"; cd "$U"
git init -q -b master; git config user.email t@t; git config user.name t
mkdir -p srcpkgs/a srcpkgs/b srcpkgs/c common/environment
tmpl a 1.0 1 > srcpkgs/a/template; tmpl b 3.0 1 > srcpkgs/b/template
tmpl c 1.0 1 > srcpkgs/c/template; ln -s c srcpkgs/c-old; ln -s a srcpkgs/lnk
printf '# header\nliba.so.1 a-1.0_1\nlibz.so.1 z-1.0_1\n' > common/shlibs
echo 'X=1' > common/environment/misc.sh
git add -A; git commit -qm up

R=$T/root; mkdir -p "$R/srcpkgs/a" "$R/srcpkgs/b" "$R/srcpkgs/n" "$R/srcpkgs/lnk" "$R/common/patches"
cp "$HERE/../voidlab" "$R/"
tmpl a 2.0 1 > "$R/srcpkgs/a/template"; tmpl b 2.0 1 > "$R/srcpkgs/b/template"
tmpl n 1.0 1 > "$R/srcpkgs/n/template"; ln -s n "$R/srcpkgs/n-devel"
tmpl lnk 1.0 1 > "$R/srcpkgs/lnk/template"
printf 'liba.so.2 a-2.0_1\n' > "$R/common/shlibs"
printf 'c-old\n' > "$R/common/removed-srcpkgs"
(cd "$U" && echo 'X=2' > common/environment/misc.sh && git diff > "$R/common/patches/environment__misc.sh.patch" && git checkout -q .)

out=$("$R/voidlab" build a 2>&1 || true)
assert_grep "build without upstream says run sync" 'voidlab sync' <(echo "$out")

VOIDLAB_UPSTREAM_URL=$U VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync >/dev/null
assert_file "sync clones upstream" "$R/.upstream/srcpkgs/a/template"

"$R/voidlab" overlay
UP=$R/.upstream
assert_grep "overlay replaces a" 'version=2.0' "$UP/srcpkgs/a/template"
assert_file "overlay adds new package n" "$UP/srcpkgs/n/template"
assert_eq  "overlay copies symlink n-devel" "$(readlink "$UP/srcpkgs/n-devel")" "n"
assert_eq  "dir over upstream symlink lnk" "$([ -d "$UP/srcpkgs/lnk" ] && [ ! -L "$UP/srcpkgs/lnk" ] && echo dir)" "dir"
assert_no  "removed-srcpkgs deletes c-old" "$UP/srcpkgs/c-old"
assert_grep "shlibs: new soname appended" '^liba.so.2 a-2.0_1$' "$UP/common/shlibs"
assert_grep "shlibs: unrelated line kept" '^libz.so.1 z-1.0_1$' "$UP/common/shlibs"
assert_grep "shlibs: header comment kept" '^# header$' "$UP/common/shlibs"
assert_grep "common patch applied" 'X=2' "$UP/common/environment/misc.sh"

"$R/voidlab" overlay   # idempotent: second run starts from a clean tree
assert_eq "overlay is idempotent" "$(grep -c '^liba.so.2' "$UP/common/shlibs")" "1"

printf 'pkgname=w\nversion=${_v}\nrevision=1\n' > "$R/srcpkgs/n/template"
st=$("$R/voidlab" status)
assert_grep "status: a ahead"   'a .*1.0_1 .*ahead'   <(echo "$st")
assert_grep "status: b behind"  'b .*3.0_1 .*behind'  <(echo "$st")
assert_grep "status: n unparseable" 'n .*unparseable' <(echo "$st")
tmpl n 1.0 1 > "$R/srcpkgs/n/template"
st=$("$R/voidlab" status)
assert_grep "status: n new" 'n .*new' <(echo "$st")

printf 'liba.so.2 a-2.0_1\nliba.so.2 a-2.1_1\n' > "$R/common/shlibs"
out=$("$R/voidlab" overlay 2>&1 || true)
assert_grep "duplicate SONAME is an error" 'duplicate SONAME' <(echo "$out")
finish
