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
# fake xbps-query: the repository index is $W/index (`[-] name-version_revision  description` lines)
printf '#!/bin/sh\n[ -f "%s/index" ] && cat "%s/index"\n' "$W" "$W" > "$W/xq"; chmod +x "$W/xq"
printf '[-] glibc-2.41_1  libc\n[-] foo-1.2_1  foo\n[-] foo-devel-1.2_1  foo\n[-] good-sub-1.0_1  void ships it\n' > "$W/index"
run() { ( cd "$R" && CHECK_ROOT=$R BASE=main XLINT=$W/xlint XBPS_QUERY=$W/xq CHECK_SKIP_TESTS=1 bash "$CHECK" 2>&1 ); }
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

# 7b. a -devel package in runtime depends fails; in makedepends or a -devel subpackage it does not
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "depends=\"foo-devel bar\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "-devel in depends fails" "$rc" "1"
assert_grep "says why" 'makedepends' <(echo "$out")
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "makedepends=\"foo-devel\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "-devel in makedepends passes" "$rc" "0"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; printf "good-devel_package() {\n\tdepends=\"\${sourcepkg}>=\${version} foo-devel\"\n}\n" >> srcpkgs/good/template; ln -s good srcpkgs/good-devel'
out=$(run) && rc=0 || rc=$?
assert_eq   "-devel in a -devel subpackage passes" "$rc" "0"

# 7c. dependencies must exist at a reachable version; new subpackages need their symlink
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "makedepends=\"foo glibc\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "dependencies that exist pass" "$rc" "0"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "depends=\"libisoburn\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "a dependency nobody has fails" "$rc" "1"
assert_grep "names it" 'depends on libisoburn, which neither' <(echo "$out")
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "depends=\"foo>=1.3\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "a floor above every version on offer fails" "$rc" "1"
assert_grep "says what is on offer" 'needs foo>=1.3, but only 1.2_1' <(echo "$out")
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "depends=\"foo>=1.2 good>=1.1_1\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "reachable floors (repository and overlay) pass" "$rc" "0"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "hostmakedepends=\"foo \$(vopt_if sccache \"rust-sccache\")\"" >> srcpkgs/good/template; echo "makedepends+=\" musl-only-devel\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "build options and += branches are not checked" "$rc" "0"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; printf "good-new_package() {\n\tshort_desc=x\n}\ngood-sub_package() {\n\tshort_desc=y\n}\n" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "a new subpackage without its symlink fails" "$rc" "1"
assert_grep "names it" 'subpackage good-new, which Void does not ship' <(echo "$out")
assert_eq   "a subpackage Void ships needs no symlink here" "$(grep -c 'good-sub' <<<"$out" || true)" "0"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; printf "good-new_package() {\n\tshort_desc=x\n}\n" >> srcpkgs/good/template; ln -s good srcpkgs/good-new'
out=$(run) && rc=0 || rc=$?
assert_eq   "a new subpackage with its symlink passes" "$rc" "0"
rm -f "$W/index"
new_repo
branch bash -c 'tmpl good 1.1 1 > srcpkgs/good/template; echo "depends=\"libisoburn\"" >> srcpkgs/good/template'
out=$(run) && rc=0 || rc=$?
assert_eq   "without repositories the check is skipped, not failed" "$rc" "0"
assert_grep "and says so" 'dependency check skipped' <(echo "$out")
printf '[-] glibc-2.41_1  libc\n' > "$W/index"

# 8. shell syntax errors in tools/ fail
new_repo
branch bash -c 'echo "if then" > tools/bad.sh'
out=$(run) && rc=0 || rc=$?
assert_eq "unparsable tools script fails" "$rc" "1"
finish
