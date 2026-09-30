# shellcheck shell=bash
# Tiny assertion helpers shared by the voidlab tests.
FAILS=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS+1)); }
assert_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3] got [$2]"; fi; }
assert_file() { if [ -e "$2" ]; then ok "$1"; else fail "$1: missing $2"; fi; }
assert_no()   { if [ ! -e "$2" ] && [ ! -L "$2" ]; then ok "$1"; else fail "$1: unexpected $2"; fi; }
assert_grep() { if grep -q -- "$2" "$3"; then ok "$1"; else fail "$1: [$2] not in $3"; fi; }
finish()      { [ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }; }
tmpl() { printf 'pkgname=%s\nversion=%s\nrevision=%s\n' "$1" "$2" "$3"; }
