# voidlab

Personal xbps-src template overlay and local binary repository.

This repo is the **source of truth for every custom template**: packages
that don't exist in Void (COSMIC, caerus, pop-launcher, …) and modified
upstream ones (GNOME 51 stack, Cinnamon, elogind, eudev, lightdm, gcc 16,
PAM 1.7.3, …). It holds only those templates — not the full
void-packages tree. Builds overlay them onto a stock upstream checkout.

## Layout

| Path | What |
|---|---|
| `srcpkgs/<pkg>/` | custom templates (+ `files/`, `patches/`, subpackage symlinks) |
| `common/shlibs` | only added/changed SONAME lines; merged over upstream's by SONAME |
| `common/patches/*.patch` | changes to upstream `common/` files, applied with `git apply` |
| `common/removed-srcpkgs` | upstream `srcpkgs/` entries deleted before building |
| `IMPORT.md` | provenance of the initial import (branch + commit per package) |
| `.upstream/` | stock void-packages clone — disposable, never edit (gitignored) |
| `hostdir/`, `masterdir/` | xbps-src caches and build chroot (gitignored) |
| `repo/` | built packages + `x86_64-repodata` (gitignored) |

## Commands

```sh
./voidlab sync              # clone/refresh .upstream, bootstrap masterdir
./voidlab build <pkg>...    # overlay, build sequentially, index into repo/
./voidlab status            # compare every template against upstream
./voidlab overlay           # apply the overlay only (debugging)
```

`build` refuses to run while another xbps-src build is active, and stops
at the first failure (log in `hostdir/voidlab-build-<pkg>.log`).

This machine installs from the repo via `/etc/xbps.d/20-voidlab.conf`:

```
repository=/home/gui/Projects/voidlab/voidlab/repo
bestmatching=true
```

`bestmatching=true` is required: by default xbps takes a package from the
*first* repository that has it, and the official repos sort first, so
overlay builds of packages that also exist upstream would be ignored.
With it, the highest version across all repos wins — overlay builds win
only while they are newer. The repo is local and unsigned.

Per-machine xbps-src settings (makejobs, `XBPS_ALLOW_RESTRICTED`, ccache)
go in `~/.xbps-src.conf`: `.upstream/etc/conf` is wiped on every build.

### `status` verdicts

| Verdict | Meaning | Action |
|---|---|---|
| `new` | not in upstream | keep |
| `ahead` | our version is newer | keep (normal) |
| `same-ver` | same version as upstream, different template | local patch without a revision bump — keep, or bump revision |
| `redundant` | identical to upstream | delete from `srcpkgs/` |
| `behind` | upstream is newer | drop ours, or rebase it onto upstream's template |
| `unparseable` / `check` | version uses a variable | inspect by hand |

The last column shows whether `repo/` has the current build (`ok`,
`unbuilt`, `stale(<ver>)`).

## Workflow

- Edit templates **here**. To send one upstream, copy it into a branch of
  `~/Projects/voidlab/void-packages` and open the PR from there.
- After upstream catches up, `status` reports the package `redundant` or
  `behind`; delete it from `srcpkgs/`.
- Tests: `bash tests/test-import.sh && bash tests/test-voidlab.sh`.

Design: `docs/superpowers/specs/2026-09-30-voidlab-overlay-repo-design.md`.
