#!/usr/bin/env bash
# tools/ci-overlay-report.sh: one issue with the prefer-official list and non-auto-updated releases.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'

W=$T/work; mkdir -p "$W/tools" "$T/bin"
cp "$HERE/../tools/ci-overlay-report.sh" "$W/tools/" 2>/dev/null || true
printf '# leaf apps\na\n' > "$W/tools/auto-update.allow"

cat > "$T/vl" <<STUB
#!/bin/bash
echo "\$*" >> "$T/calls.log"
case "\$1 \${2:-}" in
"redundant ") cat "$T/redundant" ;;
"update --all") cat "$T/update" ;;
esac
exit 0
STUB
cat > "$T/bin/gh" <<SHIM
#!/bin/bash
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
"issue list") [ -f "$T/existing" ] && echo 7 ;;
"issue create"|"issue edit")
	while [ \$# -gt 0 ]; do [ "\$1" = --body-file ] && cp "\$2" "$T/body.md"; shift; done ;;
esac
exit 0
SHIM
chmod +x "$T/vl" "$T/bin/gh"
export PATH=$T/bin:$PATH VOIDLAB_BIN=$T/vl
run() { (cd "$W" && bash tools/ci-overlay-report.sh) 2>&1; }

printf 'revbump\tcheese\t44.1_5\t44.1_4\nbehind\told\t1.0_1\t2.0_1\n' > "$T/redundant"
printf 'bump\ta\t1.0_1\t1.1\nbump\tglib\t2.90.0_1\t2.91.0\ncurrent\tb\t1.0_1\t-\nfail\tx\t-\tno overlay template\n' > "$T/update"
: > "$T/calls.log"; : > "$T/gh.log"
run >/dev/null
assert_grep "syncs upstream first"              '^sync$' "$T/calls.log"
assert_grep "creates the issue when none is open" 'issue create --title Overlay report --label overlay-report' "$T/gh.log"
assert_grep "lists a redundant package"         '^| revbump | cheese | 44.1_5 | 44.1_4 |$' "$T/body.md"
assert_grep "lists a package behind official"   '^| behind | old | 1.0_1 | 2.0_1 |$' "$T/body.md"
assert_grep "lists a stack bump"                '^| glib | 2.90.0_1 | 2.91.0 |$' "$T/body.md"
assert_eq   "auto-updated packages are left out" "$(grep -c '| a |' "$T/body.md" || true)" "0"
assert_eq   "current and failed packages are left out" "$(grep -cE '\| (b|x) \|' "$T/body.md" || true)" "0"

echo existing > "$T/existing"; : > "$T/gh.log"
run >/dev/null
assert_grep "edits the open issue instead of opening another" 'issue edit 7 --body-file' "$T/gh.log"
assert_eq   "no second issue is created"        "$(grep -c 'issue create' "$T/gh.log" || true)" "0"

: > "$T/redundant"; : > "$T/update"
run >/dev/null
assert_grep "empty report says so"              'Nothing: every overlay template' "$T/body.md"
finish
