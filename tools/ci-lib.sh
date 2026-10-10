# shellcheck shell=bash
# Shared by tools/ci-build.sh, tools/ci-publish.sh and `voidlab test`. Reads the trusted checkout only
# (text, nothing is executed); all run from the repository root.

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

# declared <template> <key> <version> <revision>: the words a template assigns to `key` (text only, nothing
# executed), on any line including subpackage functions, with the simple expansions applied; a mention in a
# comment or a longer word does not count
declared() {
	perl -0ne 'while (/^[ \t]*'"$2"'=["\x27]?([^"\x27]*)["\x27]?/mg) { print "$1\n" }' "srcpkgs/$1/template" | tr -s ' \t\n' '\n\n\n' |
		sed -e "s/\${pkgname}/$1/g" -e "s/\$pkgname/$1/g" -e "s/\${version}/$3/g" -e "s/\$version/$3/g" \
			-e "s/\${revision}/$4/g" -e "s/\$revision/$4/g"
}

# shlibs_owner <soname> <shlibs file>...: the package name common/shlibs gives the soname (later files win;
# empty when none lists it)
shlibs_owner() {
	local so=$1 f files=(); shift
	for f; do [ -f "$f" ] && files+=("$f"); done
	[ ${#files[@]} -gt 0 ] || return 0
	awk -v s="$so" '$1 == s { m = $2 } END { print m }' "${files[@]}" | sed -E 's/-[^-]+_[0-9]+$//'
}

# (grep -q is fed by here-strings below, never by a pipe: it exits at the first match, and under pipefail
# the writer's SIGPIPE would turn a match into a failure)
# pkg_meta_problems <repo> <file name> <owner> <shlibs file>...: one line per thing in a built package that
# can change what other packages resolve to and that neither its template nor its own files account for.
# <repo> is an indexed repository holding the package; nothing in the package is executed. The rules follow
# xbps-src: hooks/pre-pkg/04-generate-provides.sh adds pc: for every .pc file, cmd: for every /usr/bin file
# (cmd:X-0_1 for an alternatives link), py3: for python metadata; post-install/98-shlib-provides.sh adds the
# ELF SONAME of every shared library. A soname is accepted when a library of that name is in the package and
# common/shlibs does not give it to a package of another template.
pkg_meta_problems() {
	local repo=$1 b=$2 owner=$3; shift 3
	local name vr ver rev key v x files alts so mapped
	[[ $b =~ ^(.+)-([0-9][0-9A-Za-z.+~]*_[0-9]+)\.(x86_64|noarch)\.xbps$ ]] || { echo "invalid package file name: $b"; return; }
	name=${BASH_REMATCH[1]} vr=${BASH_REMATCH[2]}
	ver=${vr%_*} rev=${vr##*_}
	_meta() { XBPS_ARCH=x86_64 xbps-query -i -R --repository="$repo" -p "$1" "$name" 2>/dev/null; }
	files=$(XBPS_ARCH=x86_64 xbps-query -i -R --repository="$repo" -f "$name" 2>/dev/null | sed 's/ -> .*//')
	alts=$(_meta alternatives)
	has() { grep -qxF -- "$1" <<<"$files"; }
	for key in provides replaces reverts conflicts alternatives; do
		while IFS= read -r v; do
			[ -n "$v" ] || continue
			grep -qxF -- "$v" <<<"$(declared "$owner" "$key" "$ver" "$rev")" && continue
			if [ "$key" = provides ]; then
				case $v in
				pc:*-"$vr") x=${v#pc:}; x=${x%-"$vr"}
					{ has "/usr/lib/pkgconfig/$x.pc" || has "/usr/share/pkgconfig/$x.pc"; } && continue ;;
				cmd:*-"$vr") x=${v#cmd:}; x=${x%-"$vr"}
					has "/usr/bin/$x" && continue ;;
				cmd:*-0_1) x=${v#cmd:}; x=${x%-0_1}
					awk -F: -v x="$x" '{ n = split($2, p, "/"); if (p[n] == x) f = 1 } END { exit !f }' <<<"$alts" && continue ;;
				py3:*-"$vr")
					grep -qE '^/usr/lib/python3[^/]*/site-packages/[^/]+\.(dist|egg)-info(/|$)' <<<"$files" && continue ;;
				esac
			fi
			echo "$b declares $key $v, which the template of $owner does not and its files do not account for"
		done < <(_meta "$key")
	done
	while IFS= read -r so; do
		[ -n "$so" ] || continue
		if ! [[ $so =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.so(\.[0-9]+)*$ ]]; then echo "$b has an invalid shlib-provides: $so"; continue; fi
		if ! awk -v s="${so%%.so*}.so" '{ n = split($0, p, "/"); if (index(p[n], s) == 1) f = 1 } END { exit !f }' <<<"$files"; then
			echo "$b has shlib-provides $so, but no such library is in it"; continue
		fi
		mapped=$(shlibs_owner "$so" "$@")
		if [ -n "$mapped" ] && ! grep -qxF -- "$mapped" <<<"$(allowed_names "$owner")"; then
			echo "$b has shlib-provides $so, which common/shlibs gives to $mapped (not a package of $owner)"
		fi
	done < <(_meta shlib-provides)
}
