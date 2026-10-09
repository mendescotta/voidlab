#!/usr/bin/env bash
# tools/update-tiers and `voidlab tiers`: auto | review | manual | (unlisted = notify).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'

R=$T/root; mkdir -p "$R/tools"; cp "$HERE/../voidlab" "$R/"
for p in a r m n; do mkdir -p "$R/srcpkgs/$p"; tmpl $p 1.0 1 > "$R/srcpkgs/$p/template"; done
printf '# tiers\na auto\nr review  # needs a look\nm manual\n\n' > "$R/tools/update-tiers"

out=$(cd "$R" && ./voidlab tiers)
assert_grep "auto is listed"            "^a${tab}auto\$"   <(echo "$out")
assert_grep "review is listed"          "^r${tab}review\$" <(echo "$out")
assert_grep "manual is listed"          "^m${tab}manual\$" <(echo "$out")
assert_grep "unlisted is notify"        "^n${tab}notify\$" <(echo "$out")
assert_eq   "one line per template"     "$(wc -l <<<"$out")" "4"

# a typo in a tier must stop everything, not silently demote a package
printf 'a auto\nr reveiw\n' > "$R/tools/update-tiers"
out=$(cd "$R" && ./voidlab tiers 2>&1) && rc=0 || rc=$?
assert_eq   "unknown tier fails"        "$rc" "1"
assert_grep "names the bad line"        'reveiw' <(echo "$out")
printf 'a auto extra\n' > "$R/tools/update-tiers"
out=$(cd "$R" && ./voidlab tiers 2>&1) && rc=0 || rc=$?
assert_eq   "extra field fails"         "$rc" "1"

# no file: everything is notify
rm "$R/tools/update-tiers"
out=$(cd "$R" && ./voidlab tiers)
assert_grep "no file means notify"      "^a${tab}notify\$" <(echo "$out")

# the real file: valid, no duplicates, every entry names an existing template
REAL=$HERE/../tools/update-tiers
assert_eq "real update-tiers: no duplicate names" "$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$REAL" | sort | uniq -d | wc -l)" "0"
assert_eq "real update-tiers: every line is valid" "$(awk '{ sub(/#.*/, "") } NF && (NF != 2 || $2 !~ /^(auto|review|manual)$/)' "$REAL" | wc -l)" "0"
missing=$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$REAL" | while read -r p; do [ -f "$HERE/../srcpkgs/$p/template" ] || echo "$p"; done)
assert_eq "real update-tiers: every package has a template ($missing)" "$missing" ""
assert_eq "real update-tiers: nvidia is never auto or review" "$(grep -cE '^nvidia (auto|review)' "$REAL" || true)" "0"
finish
