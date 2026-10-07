#!/usr/bin/env bash
# Policy checks on .github/workflows (no YAML parser on the host): the signing key must stay in one
# step, nothing fork-driven may trigger these jobs, dispatch inputs never reach a shell directly.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
ROOT=${WORKFLOW_ROOT:-$HERE/..}
W=$ROOT/.github/workflows
shopt -s nullglob
files=("$W"/*.yml)
[ ${#files[@]} -gt 0 ] || { echo "no workflows in $W"; exit 1; }

for f in "${files[@]}"; do
	n=${f##*/}
	assert_eq "$n: no pull_request / workflow_run trigger" "$(grep -cE '^\s*(pull_request|pull_request_target|workflow_run)\b' "$f" || true)" "0"
	assert_grep "$n: declares permissions"      '^permissions:' "$f"
	assert_grep "$n: declares concurrency"      '^concurrency:' "$f"
	assert_eq "$n: no tab characters"           "$(grep -c $'\t' "$f" || true)" "0"
	assert_eq "$n: inputs only reach the shell through env" \
		"$(grep -E '\$\{\{ *(inputs|github\.event\.(inputs|issue|pull_request|head_commit))' "$f" | grep -vcE '^\s+[A-Z_]+: ' || true)" "0"
	assert_eq "$n: never prints a secret"       "$(grep -ciE 'echo.*(secrets\.|PRIVKEY)' "$f" || true)" "0"
	for s in $(grep -oE 'tools/[a-z-]+\.(sh)' "$f" | sort -u); do
		assert_file "$n: $s exists" "$ROOT/$s"
		if bash -n "$ROOT/$s" 2>/dev/null; then ok "$n: $s parses"; else fail "$n: $s does not parse"; fi
	done
done

U=$W/auto-update.yml
build=$(awk '/^  build:/ { on = 1; next } /^  publish:/ { on = 0 } on' "$U")
publish=$(awk '/^  publish:/ { on = 1; next } on' "$U")
[ -n "$build" ] && [ -n "$publish" ] || { fail "auto-update.yml has a build and a publish job"; finish; }

assert_eq "the signing secret is referenced exactly once" "$(grep -h 'secrets\.' "${files[@]}" | grep -c 'secrets.VOIDLAB_PRIVKEY')" "1"
assert_eq "no other secret is referenced"          "$(grep -h 'secrets\.' "${files[@]}" | grep -vc 'secrets.VOIDLAB_PRIVKEY' || true)" "0"
assert_eq "the secret lives in the publish job"    "$(grep -c 'secrets\.VOIDLAB_PRIVKEY' <<<"$publish")" "1"
assert_eq "the build job has no secrets"           "$(grep -c 'secrets\.' <<<"$build" || true)" "0"
assert_grep "build job is read-only"               'contents: read' <(echo "$build")
assert_eq "build job has no write permission"      "$(grep -cE '(contents|pull-requests|issues|packages|id-token): write' <<<"$build" || true)" "0"
assert_grep "build checkout keeps no git credentials" 'persist-credentials: false' <(echo "$build")
assert_grep "build job runs the build script"      'tools/ci-build.sh' <(echo "$build")
assert_eq "build job never runs the publish script" "$(grep -c 'ci-publish' <<<"$build" || true)" "0"
assert_grep "builds never run as root"             'sudo -Eu builder' <(echo "$build")
assert_grep "build job hands data over as an artifact" 'upload-artifact' <(echo "$build")
assert_grep "publish job needs the build job"      'needs: build' <(echo "$publish")
assert_grep "publish job runs the publish script"  'tools/ci-publish.sh' <(echo "$publish")
for bad in 'ci-build' 'voidlab build' 'xbps-src' 'sudo -Eu builder' '\-\-privileged'; do
	assert_eq "publish job never uses: $bad"       "$(grep -c -- "$bad" <<<"$publish" || true)" "0"
done
assert_grep "publish job checks out the trusted repo itself" 'actions/checkout' <(echo "$publish")
assert_grep "the artifact lands outside the workspace" 'path: \${{ runner.temp }}' <(echo "$publish")
assert_grep "publish job downloads the artifact"   'download-artifact' <(echo "$publish")

# the build script is read-only by construction; the publish script never executes artifact content
assert_eq "ci-build.sh pushes, opens and publishes nothing" "$(grep -cE 'git push|gh +(pr|issue|release)|"\$VL" +publish' "$ROOT/tools/ci-build.sh" || true)" "0"
assert_eq "ci-build.sh only ever strips the signing key" "$(grep 'VOIDLAB_PRIVKEY' "$ROOT/tools/ci-build.sh" | grep -vc -- '-u VOIDLAB_PRIVKEY' || true)" "0"
assert_eq "ci-publish.sh never executes artifact content" "$(grep -cE '(^|[[:space:];&|(])(source|\.|bash|sh|exec|eval|python3|perl) +["]?\$BUILD_OUT' "$ROOT/tools/ci-publish.sh" || true)" "0"
assert_grep "dependabot watches github-actions" 'package-ecosystem: github-actions' "$ROOT/.github/dependabot.yml"
finish
