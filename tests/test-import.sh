#!/usr/bin/env bash
# Builds a fake void-packages repo with an origin/master base and two
# branches, runs the importer, and checks what it picked.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/src; mkdir -p "$S"; cd "$S"
git init -q -b master; git config user.email t@t; git config user.name t
mkdir -p srcpkgs/a srcpkgs/b srcpkgs/gone common/environment
tmpl a 1.0 1 > srcpkgs/a/template; tmpl b 1.0 1 > srcpkgs/b/template
tmpl gone 1.0 1 > srcpkgs/gone/template
ln -s b srcpkgs/b-old
printf 'liba.so.1 a-1.0_1\nlibb.so.1 b-1.0_1\n' > common/shlibs
echo 'X=1' > common/environment/misc.sh
git add -A; git commit -qm base; git update-ref refs/remotes/origin/master HEAD
# branch x: a -> 2.0, new c + c-devel symlink, shlibs bump, misc.sh edit, drop b-old
git checkout -qb x
tmpl a 2.0 1 > srcpkgs/a/template; mkdir srcpkgs/c; tmpl c 1.0 1 > srcpkgs/c/template
ln -s c srcpkgs/c-devel; git rm -q srcpkgs/b-old
printf 'liba.so.2 a-2.0_1\nlibb.so.1 b-1.0_1\n' > common/shlibs
echo 'X=2' > common/environment/misc.sh
git add -A; git commit -qm x
# branch y (from base): a -> 1.5, b touched but reverted to identical, gone deleted,
# weird has an unparseable version, c exists at 0.9
git checkout -q master; git checkout -qb y
tmpl a 1.5 1 > srcpkgs/a/template; git rm -qr srcpkgs/gone
mkdir srcpkgs/weird; printf 'pkgname=weird\nversion=${_v}\nrevision=1\n' > srcpkgs/weird/template
mkdir srcpkgs/c; tmpl c 0.9 1 > srcpkgs/c/template
git add -A; git commit -qm y1; echo '# tmp' >> srcpkgs/b/template; git commit -qam y2
git checkout -q HEAD~1 -- srcpkgs/b/template; git commit -qam y3
# branch z: deletes a, which x/y keep -> must not become a removal
git checkout -q master; git checkout -qb z; git rm -qr srcpkgs/a; git commit -qm z
git checkout -q master

D=$T/dest; mkdir "$D"
"$HERE/../tools/import-from-void-packages" --src "$S" --dest "$D" x y z

assert_grep "a picks highest version (2.0 from x)" 'version=2.0' "$D/srcpkgs/a/template"
assert_grep "c picks 1.0 over 0.9" 'version=1.0' "$D/srcpkgs/c/template"
assert_eq  "c-devel imported as symlink" "$(readlink "$D/srcpkgs/c-devel")" "c"
assert_no  "b identical to base is skipped" "$D/srcpkgs/b"
assert_file "weird (unparseable) still imported" "$D/srcpkgs/weird/template"
assert_grep "gone recorded as removed" '^gone$' "$D/common/removed-srcpkgs"
assert_grep "b-old symlink recorded as removed" '^b-old$' "$D/common/removed-srcpkgs"
assert_eq  "a deleted on z is not a removal" "$(grep -c '^a$' "$D/common/removed-srcpkgs" || true)" "0"
assert_eq  "shlibs holds only changed lines" "$(cat "$D/common/shlibs")" "liba.so.2 a-2.0_1"
assert_file "misc.sh patch written" "$D/common/patches/environment__misc.sh.patch"
assert_grep "IMPORT.md lists a from x" '| a | 2.0_1 | x |' "$D/IMPORT.md"
finish
