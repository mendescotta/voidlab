# voidlab

Custom Void Linux packages (COSMIC, GNOME 51, Cinnamon, caerus, …) as xbps
templates, plus a signed binary repository (x86_64, glibc).

## Install packages

```sh
echo 'repository=https://github.com/mendescotta/voidlab/releases/download/repo' |
    sudo tee /etc/xbps.d/20-voidlab.conf
echo 'bestmatching=true' | sudo tee -a /etc/xbps.d/20-voidlab.conf
sudo xbps-install -S          # accept the voidlab signing key when asked
sudo xbps-install <package>   # e.g. caerus, cosmic-desktop
```

`bestmatching=true` makes the newest version across all repositories win, so
packages that also exist in Void's repos are taken from here only while they
are newer.

## Build (maintainer)

```sh
./voidlab sync              # clone upstream void-packages, bootstrap masterdir
./voidlab build <pkg>...    # overlay templates, build, index into repo/
```

Templates live in `srcpkgs/`. To use a local build instead of the release, set
`repository=/path/to/voidlab/repo`. Other subcommands: `status`, `tiers`,
`update [--check]`, `test <pkg>`, `redundant`, `packages`, `keygen`, `publish`.

## Packages

[packages.md](packages.md) lists every template with its version here, in
official Void and upstream. Regenerate with `./voidlab packages > packages.md`.

## CI

Daily auto-update (tiers `auto`/`review`/`manual`), PR checks, a weekly overlay
report and a watchdog. Details, setup and the trust model: [docs/ci.md](docs/ci.md).
nvidia is on `tools/never-publish` and is never published.
