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

# name_map_load: fill NAME_OWNER[<package name>]=<template> for every overlay template (itself, declared
# subpackages, symlinked subpackage directories). Loaded once.
declare -gA NAME_OWNER=()
NAME_MAP_LOADED=
name_map_load() {
	local d t n
	[ -z "$NAME_MAP_LOADED" ] || return 0
	for d in srcpkgs/*/; do
		t=${d%/}; t=${t##*/}
		[ -L "srcpkgs/$t" ] && continue
		[ -f "srcpkgs/$t/template" ] || continue
		while IFS= read -r n; do NAME_OWNER[$n]=$t; done < <(allowed_names "$t")
	done
	NAME_MAP_LOADED=1
}

# owner_of <package name>: the overlay template that produces it (fails when none does)
owner_of() {
	name_map_load
	[ -n "${NAME_OWNER[$1]:-}" ] && echo "${NAME_OWNER[$1]}"
}

# template_verrev <template>: version_revision from the template text (fails when unreadable)
template_verrev() {
	local v r
	v=$(sed -n 's/^version=//p' "srcpkgs/$1/template" | head -n1 | tr -d "\"'")
	r=$(sed -n 's/^revision=//p' "srcpkgs/$1/template" | head -n1 | tr -d "\"'")
	[[ $v =~ ^[0-9][0-9A-Za-z.+~]*$ ]] && [[ $r =~ ^[0-9]+$ ]] || return 1
	echo "${v}_${r}"
}

# dep_words <template>: the package names its depends/makedepends/hostmakedepends mention (text only)
dep_words() {
	perl -0ne 'while (/^[ \t]*(?:depends|makedepends|hostmakedepends)[ \t]*\+?=[ \t]*(?:"([^"]*)"|\x27([^\x27]*)\x27)/mg) { my $v = defined $1 ? $1 : $2; print "$_\n" for split /\s+/, $v }' "srcpkgs/$1/template" |
		sed -E 's/[<>=].*$//' | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' | sort -u
}

# deps_closure <template>...: those templates plus every overlay template they need to build or run
deps_closure() {
	local -A seen=()
	local queue=("$@") t w o
	name_map_load
	while [ ${#queue[@]} -gt 0 ]; do
		t=${queue[0]}; queue=("${queue[@]:1}")
		[ -z "${seen[$t]:-}" ] || continue
		seen[$t]=1
		[ -f "srcpkgs/$t/template" ] || continue
		while IFS= read -r w; do
			o=${NAME_OWNER[$w]:-}
			[ -n "$o" ] && [ -z "${seen[$o]:-}" ] && queue+=("$o")
		done < <(dep_words "$t")
	done
	printf '%s\n' "${!seen[@]}"
}
