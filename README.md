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
`voidlands` checkout (`../voidlands`, or `$VOIDLAB_EXTRA_SRCPKGS`;
currently `chimerautils`) are overlaid and built the same way. To use the local build on the same
machine instead of the release, set `repository=/path/to/voidlab/repo`.
