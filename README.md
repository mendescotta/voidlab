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

## Build and publish (maintainer)

```sh
./voidlab sync              # clone upstream void-packages, bootstrap masterdir
./voidlab build <pkg>...    # overlay templates, build, index into repo/
./voidlab keygen            # once: signing key in ~/.config/voidlab/
./voidlab publish           # sign and upload repo/ to the `repo` release
```

Custom templates live in `srcpkgs/`. Templates kept in a sibling
`voidlands` checkout (`../voidlands`, or `$VOIDLAB_EXTRA_SRCPKGS`; currently empty) are overlaid
and built the same way. To use the local build on the same
machine instead of the release, set `repository=/path/to/voidlab/repo`.

## Automatic updates

`.github/workflows/auto-update.yml` runs daily (and by hand, optionally for one package) in two jobs.
The read-only `build` job (no secrets, read-only token, no persisted git credentials, because it runs
third-party build scripts) takes every template in the `auto` and `review` tiers of `tools/update-tiers`, asks `xbps-src
update-check` for the newest **stable** upstream release (pre-releases and anything that is not a
plain version string are ignored), bumps the template, builds and tests it, and hands plain data to
the `publish` job as an artifact. `publish` runs on a fresh runner from the trusted checkout, treats
that artifact as untrusted data (`tools/ci-publish.sh` aborts the whole run unless it has the expected
shape: only the version, revision and checksum lines of a template may change, and only the
package's own declared subpackages at the expected version may be published), opens one PR per
passing bump (`<pkg> <version>`) and, for tier `auto`, merges and publishes it. Tier `review` leaves the
PR open: merge it and the next daily run builds and publishes the merged version. It is the only job with a write token and the
signing key. A failing package opens or updates one `auto-update failed: <pkg>` issue and never blocks
the others. Libraries, the toolchain and the session stack are tier `manual`: bump those by hand
(`./voidlab tiers` lists every template with its tier).
`.github/workflows/overlay-report.yml` opens one weekly `Overlay report` issue with the templates
official Void has caught up with (add the ones that must stay to `tools/keep-overlay.list`) and the
newer upstream releases that are not auto-updated.
`.github/workflows/watchdog.yml` opens a `ci-watchdog` issue when a scheduled run stops succeeding, and
`.github/workflows/check.yml` lints the templates and patches a pull request touches (`tools/ci-check.sh`).

The steps are ordinary subcommands, so CI and a laptop behave the same:

```sh
./voidlab update --check     # TSV: bump | current | unpublished | fail (auto + review tiers; --all for every template)
./voidlab tiers              # every template with its update tier
./voidlab update <pkg>       # bump the template (version, revision=1, checksum)
./voidlab test <pkg>...      # built version matches the template, dependencies and sonames resolve
./voidlab redundant          # overlay templates at or behind official Void, minus the keep list
./voidlab pull               # CI only: seed repo/ from the release (it would restore removed packages)
```

One-time setup the workflows cannot do themselves: add the repository secret `VOIDLAB_PRIVKEY`
(the contents of `~/.config/voidlab/privkey.pem`) and allow Actions to create and approve pull
requests (Settings, Actions, General). nvidia is tier `manual` and is never published.
