#!/usr/bin/env bash
# dbus-wait-for must not take the wrapped command's own options for its own (glibc getopt permutes
# arguments; without the "+" prefix "NetworkManager -n" died with a usage error and the service never ran).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/srcpkgs/dinit-void/files/dbus-wait-for.c"
W="$(mktemp -d)"
trap 'rm -rf --one-file-system "$W"' EXIT
gcc -o "$W/dbus-wait-for" "$SRC" $(pkg-config --cflags --libs dbus-1) || { echo "FAIL could not compile dbus-wait-for"; exit 1; }

fails=0
# Without a system bus the wrapper reports a connection error once its arguments parsed fine; a usage
# error (argument parsing) is the failure we guard against.
run() { "$W/dbus-wait-for" "$@" 3</dev/null 2>&1 | head -3; }
check() {
	if echo "$2" | grep -q "$3"; then echo "ok   $1"; else echo "FAIL $1: $2"; fails=$((fails + 1)); fi
}
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent
check "command with a short option (NetworkManager -n)" "$(run -s -f 3 -n org.x.Y /usr/bin/true -n)" "connection error"
check "command with a long option (polkitd --no-debug)" "$(run -s -f 3 -n org.x.Y /usr/bin/true --no-debug)" "connection error"
check "command without options" "$(run -s -f 3 -n org.x.Y /usr/bin/true)" "connection error"
[ "$fails" -eq 0 ]
