#!/usr/bin/env bash
# voidlab redundant: overlay templates official Void has caught up with.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'
mk() { # <root>/srcpkgs <pkg> <version> <revision> <makedepends>
	mkdir -p "$1/$2"; printf 'pkgname=%s\nversion=%s\nrevision=%s\nmakedepends="%s"\n' "$2" "$3" "$4" "$5" > "$1/$2/template"
}

U=$T/upstream; mkdir -p "$U/srcpkgs"; cd "$U"
git init -q -b master; git config user.email t@t; git config user.name t
mk "$U/srcpkgs" ident 1.0 1 x; mk "$U/srcpkgs" revb 1.0 1 x; mk "$U/srcpkgs" samev 1.0 1 x
mk "$U/srcpkgs" samev2 1.0 1 x; mk "$U/srcpkgs" samev3 1.0 1 x; mk "$U/srcpkgs" behind 2.0 1 x
mk "$U/srcpkgs" ahead 1.0 1 x; mk "$U/srcpkgs" kept 1.0 1 x
git add -A; git commit -qm up

R=$T/root; mkdir -p "$R/tools"; cp "$HERE/../voidlab" "$R/"
O=$R/srcpkgs
mk "$O" ident 1.0 1 x       # same content, same revision
mk "$O" revb 1.0 2 x        # only the revision differs
mk "$O" samev 1.0 1 y       # content differs
mk "$O" samev2 1.0 2 y      # content and revision differ
mk "$O" samev3 1.0 1 x; mkdir -p "$O/samev3/patches"; echo p > "$O/samev3/patches/fix.patch"  # extra file
mk "$O" behind 1.0 1 x
mk "$O" ahead 2.0 1 x
mk "$O" newpkg 1.0 1 x      # not in Void
mk "$O" kept 1.0 1 x
printf '# keep on purpose\nkept\n' > "$R/tools/keep-overlay.list"
VOIDLAB_UPSTREAM_URL=$U VOIDLAB_NO_BOOTSTRAP=1 "$R/voidlab" sync >/dev/null

out=$("$R/voidlab" redundant)
assert_grep "identical template"                  "^identical${tab}ident${tab}1.0_1${tab}1.0_1\$" <(echo "$out")
assert_grep "revision-only difference"            "^revbump${tab}revb${tab}1.0_2${tab}1.0_1\$" <(echo "$out")
assert_grep "content differs, same revision"      "^same-ver${tab}samev${tab}1.0_1${tab}1.0_1\$" <(echo "$out")
assert_grep "content and revision differ"         "^same-ver${tab}samev2${tab}1.0_2${tab}1.0_1\$" <(echo "$out")
assert_grep "extra file counts as content"        "^same-ver${tab}samev3${tab}1.0_1${tab}1.0_1\$" <(echo "$out")
assert_grep "behind official"                     "^behind${tab}behind${tab}1.0_1${tab}2.0_1\$" <(echo "$out")
assert_eq   "ahead is silent"                     "$(grep -c "${tab}ahead${tab}" <<<"$out" || true)" "0"
assert_eq   "package not in Void is silent"       "$(grep -c "${tab}newpkg${tab}" <<<"$out" || true)" "0"
assert_eq   "keep-listed package is silent"       "$(grep -c "${tab}kept${tab}" <<<"$out" || true)" "0"
assert_eq   "exactly the six expected lines"      "$(grep -c . <<<"$out")" "6"
finish
