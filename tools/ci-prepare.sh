#!/bin/sh
# Prepare a ghcr.io/void-linux/void-glibc-full container for voidlab CI: CI mirror, tools, and the
# unprivileged `builder` user (xbps-src refuses to build as root).
set -eu

retry() {
	n=0
	until "$@"; do
		n=$((n + 1))
		[ "$n" -lt 3 ] || return 1
		echo "retrying ($n/3): $*" >&2
		sleep 5
	done
}

mkdir -p /etc/xbps.d
cp /usr/share/xbps.d/*-repository-*.conf /etc/xbps.d/
sed -i 's|repo-default|repo-ci|g' /etc/xbps.d/*-repository-*.conf

retry xbps-install -Syu xbps
retry xbps-install -yu
retry xbps-install -y sudo bash curl git github-cli xtools openssl perl

id builder >/dev/null 2>&1 || useradd -G xbuilder -m builder
# the checkout is owned by another uid than the one running git
git config --system --add safe.directory '*'
