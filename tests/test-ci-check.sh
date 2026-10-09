#!/usr/bin/env bash
# tools/ci-check.sh: the pull-request gate. Fake git tree, fake xlint.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
CHECK=$HERE/../tools/ci-check.sh
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tab=$'\t'
export -f tmpl

# fake xlint: prints what $FAKE_XLINT_OUT says for each template argument
cat > "$W/xlint" <<'X'
#!/bin/sh
for t in "$@"; do
	grep "^$t:" "$FAKE_XLINT_OUT" 2>/dev/null || true
done
exit 0
X
chmod +x "$W/xlint"

new_repo() {
	R=$W/repo; rm -rf "$R"; mkdir -p "$R/srcpkgs/good" "$R/tools"
	( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
	  tmpl good 1.0 1 > srcpkgs/good/template
	  printf '# known\n' > tools/xlint-known.txt
	  git add -A && git commit -q -m base )
	: > "$W/xlint.out"; export FAKE_XLINT_OUT=$W/xlint.out
}
run() { ( cd "$R" && CHECK_ROOT=$R BASE=main XLINT=$W/xlint CHECK_SKIP_TESTS=1 bash "$CHECK" 2>&1 ); }
branch() { ( cd "$R" && git checkout -q -b "b$RANDOM" && "$@" && git add -A && git commit -q -m change ); }

# 1. no changes -> passes
new_repo
out=$(run) && rc=0 || rc=$?
assert_eq "no changes passes" "$rc" "0"

# 2. a changed template with a clean xlint passes
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq "clean changed template passes" "$rc" "0"

# 3. a new xlint finding fails; the same finding listed as known passes
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template'
echo "srcpkgs/good/template:3: wrksrc is deprecated and should not be used" > "$W/xlint.out"
out=$(run) && rc=0 || rc=$?
assert_eq "unknown xlint finding fails" "$rc" "1"
assert_grep "names the finding" "wrksrc is deprecated" <(echo "$out")
echo "srcpkgs/good/template: wrksrc is deprecated and should not be used" >> "$R/tools/xlint-known.txt"
( cd "$R" && git add -A && git commit -q -m known )
out=$(run) && rc=0 || rc=$?
assert_eq "known xlint finding passes" "$rc" "0"

# 4. an untouched template is not linted
new_repo
echo "srcpkgs/good/template:3: wrksrc is deprecated and should not be used" > "$W/xlint.out"
branch bash -c 'echo x > README'
out=$(run) && rc=0 || rc=$?
assert_eq "untouched template is not linted" "$rc" "0"

# 5. hardcoded own version in distfiles fails
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "distfiles=\"https://x.org/good-1.1.tar.xz\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq "hardcoded version in distfiles fails" "$rc" "1"
assert_grep "says why" 'hardcodes the version' <(echo "$out")

# 6. \${version} in distfiles is fine
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "distfiles=\"https://x.org/good-\${version}.tar.xz\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq "\${version} in distfiles passes" "$rc" "0"

# 7. a new patch needs a reason
new_repo
branch bash -c 'mkdir -p srcpkgs/good/patches; printf -- "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n" > srcpkgs/good/patches/fix.patch'
out=$(run) && rc=0 || rc=$?
assert_eq "patch without a reason fails" "$rc" "1"
assert_grep "names the patch" 'fix.patch' <(echo "$out")
new_repo
branch bash -c 'mkdir -p srcpkgs/good/patches; printf "# Why: x\n# Upstream: none\n# Drop when: never\n\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n" > srcpkgs/good/patches/fix.patch'
out=$(run) && rc=0 || rc=$?
assert_eq "patch with a Why header passes" "$rc" "0"
new_repo
branch bash -c 'mkdir -p srcpkgs/good/patches; printf "From: A <a@b>\nSubject: [PATCH] fix thing\n\nbody\n---\n a | 2 +-\n" > srcpkgs/good/patches/fix.patch'
out=$(run) && rc=0 || rc=$?
assert_eq "git-format patch with a Subject passes" "$rc" "0"

# 8. shell syntax errors in tools/ fail
new_repo
branch bash -c 'echo "if then" > tools/bad.sh'
out=$(run) && rc=0 || rc=$?
assert_eq "unparsable tools script fails" "$rc" "1"
finish
