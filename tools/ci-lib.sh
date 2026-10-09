# shellcheck shell=bash
# Shared by tools/ci-build.sh and tools/ci-publish.sh. Reads the trusted checkout only (text, nothing
# is executed); both scripts run from the repository root.

# allowed_names <pkg>: the names a template may produce: itself, the subpackages it declares and the
# symlinked subpackage directories.
allowed_names() {
	local pkg=$1 t=srcpkgs/$1/template l
	echo "$pkg"
	sed -n 's/^\([A-Za-z0-9._+-][A-Za-z0-9._+-]*\)_package[[:space:]]*(.*/\1/p' "$t"
	perl -0ne 'print "$1\n" if /^subpackages=["\x27]?([^"\x27]*)["\x27]?/m' "$t" | tr -s ' \t\n' '\n\n\n' |
		sed -e "s/\${pkgname}/$pkg/g" -e "s/\$pkgname/$pkg/g"
	for l in srcpkgs/*; do
		[ -L "$l" ] && [ "$(readlink "$l")" = "$pkg" ] && echo "${l##*/}"
	done
}

# list_names <file>: the names in a one-per-line list with # comments (empty if the file is missing)
list_names() {
	sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" 2>/dev/null | awk 'NF'
}

# owner_of <package name>: the overlay template that produces it (empty when none does)
owner_of() {
	local d t names
	for d in srcpkgs/*/; do
		t=${d%/}; t=${t##*/}
		[ -L "srcpkgs/$t" ] && continue
		[ -f "srcpkgs/$t/template" ] || continue
		# not "allowed_names | grep -q": grep exits early, the writer gets SIGPIPE and pipefail turns a match into a failure
		names=$(allowed_names "$t")
		if grep -qxF -- "$1" <<<"$names"; then echo "$t"; return 0; fi
	done
	return 1
}
