# CI and automatic updates

`.github/workflows/auto-update.yml` runs daily (and by hand, optionally for one package) in two jobs.
The read-only `build` job (no secrets, read-only token, no persisted git credentials, because it runs
third-party build scripts) takes every template in the `auto` and `review` tiers of `tools/update-tiers`, asks `xbps-src
update-check` for the newest **stable** upstream release (pre-releases and anything that is not a
plain version string are ignored), bumps the template, builds and tests it, and hands plain data to
the `publish` job as an artifact. `publish` runs on a fresh runner from the trusted checkout, treats
that artifact as untrusted data (`tools/ci-publish.sh` aborts the whole run unless it has the expected
shape: only the version, revision and checksum lines of a template may change, and only the
package's own declared subpackages at the expected version may be published), opens one PR per
passing bump (`<pkg> <version>`) and, for tier `auto`, merges and publishes it. At most one bump PR per package is open at a time (a new upstream version waits until it is merged or closed). Tier `review` leaves the
PR open: merge it and the next daily run builds and publishes the merged version. It is the only job with a write token and the
signing key. A failing package opens or updates one `auto-update failed: <pkg>` issue and never blocks
the others. Tiers decide what is *bumped*: libraries, the toolchain and the session stack are tier
`manual`, bump those by hand (`./voidlab tiers` lists every template with its tier). *Publishing* is a
separate rule: any template already on `main` that is newer than the release is published, whatever its
tier, including dependencies CI had to build along the way (for example `evolution-data-server`, which
`gnome-shell` needs). Only the names in `tools/never-publish` are excluded.
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
requests (Settings, Actions, General). nvidia is on `tools/never-publish` and is never published.
