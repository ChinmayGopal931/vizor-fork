# Linux AppImage fastlane

Fastlane configuration for building and packaging Linux AppImages for external
distribution through GitHub Actions.

Run:

```bash
bundle exec fastlane linux build
bundle exec fastlane linux package
bundle exec fastlane linux release
```

The `release` lane:

1. Builds a Linux Flutter bundle for each mainnet/testnet flavor.
2. Creates an AppDir for each flavor.
3. Creates an AppImage for each flavor.
4. Generates an embedded GPG signature, detached `.asc` signature, and `.sha256`
   checksum for each flavor.
5. Prepares the artifacts under `dist/linux`.

The deployment repository's `Release` workflow creates the GitHub Release,
uploads assets, generates the update feed for multiple architectures, and
publishes the draft release.

The AppImage uses the host's GTK/GLib and desktop/graphics dependencies.
`scripts/linux-appimage/host-libraries.txt` is shared by linuxdeploy, the GStreamer
dependency copier, and the final AppDir check. Forbidden bundled libraries,
missing dependencies, or incompatible dependency versions cause packaging to
fail before signing or creating the AppImage. The build environment requires
Python 3, `readelf` (binutils), and `ldd`.

The runtime launcher ignores inherited `LD_LIBRARY_PATH` values. It searches
the two AppDir library directories first, then uses the loader's normal system
paths for host libraries. AppDir paths containing `:` or `;` are rejected because
the loader interprets those characters as search-path separators.
Run the focused launcher regression checks on Linux
with Bash, Python 3, and a C compiler:

```bash
python3 scripts/linux-appimage/test_app_run.py
```

The runtime environment needs GTK 3, a Secret Service provider, udev, and
EGL/GLES/Mesa or the appropriate GPU drivers. Minimal and server installations
may need additional packages. Relevant Ubuntu packages include `libgtk-3-0`,
`libsecret-1-0`, `libudev1`, `libegl1`, `libgles2`, and `libgl1-mesa-dri`; newer
releases use t64 package names where applicable. On Fedora, check `gtk3`,
`libsecret`, `systemd-libs`, `libglvnd-egl`, `libglvnd-gles`, `libglvnd-glx`, and
`mesa-dri-drivers`. The private legacy ABI dependencies `libjpeg.so.8` and
`libbz2.so.1.0` remain bundled for GStreamer/camera support.

The `veylor` and `veylor-testnet` flavors build Veylor's identity
(`com.veylor.desktop` and `com.veylor.desktop.testnet`, executables `veylor`
and `veylor-testnet`) through `VIZOR_APPLICATION_ID`; see "Desktop identity" in
AGENTS.md. They are not default flavors, never check for updates and embed no
update information until Veylor has release keys of its own. Their assets are
named `Veylor-linux-<arch>.AppImage` and `Veylor-Testnet-linux-<arch>.AppImage`.

The default release flavors are `mainnet,testnet`. To package a single flavor
or explicitly select both for a release:

```bash
VIZOR_LINUX_FLAVOR=mainnet bundle exec fastlane linux package
VIZOR_LINUX_FLAVOR=testnet bundle exec fastlane linux package
VIZOR_LINUX_FLAVORS=mainnet,testnet bundle exec fastlane linux release
```

## Native build dependencies

Ledger USB uses HIDAPI's `linux-static-hidraw` backend. Install `libudev-dev`
and `pkg-config` in the Linux build environment (or distribution equivalents).
The release build script checks this before building; `libudev` remains a native
runtime dependency. The AppImage dependency collector includes linked libraries.
Bundles include the Ledger udev rule and host setup instructions under
`data/ledger-usb`; packaging never changes host USB permissions automatically.

## Required environment variables

- `RELEASE_REPOSITORY`
- `RELEASE_BUILD_NUMBER`
- `LINUX_APPIMAGE_GPG_PRIVATE_KEY`, unless `LINUX_APPIMAGE_UNSIGNED=true`
- `LINUX_APPIMAGE_GPG_KEY_ID`, unless `LINUX_APPIMAGE_UNSIGNED=true`

Workflows that are not triggered by a tag also require:

- `RELEASE_TAG`

## Optional environment variables

- `RELEASE_NAME`
- `GITHUB_RELEASE_PRERELEASE`
- `VIZOR_LINUX_FLAVOR`
- `VIZOR_LINUX_FLAVORS`
- `VIZOR_LINUX_ARCH`
- `FVM_BIN`
- `LINUXDEPLOY_BIN`
- `APPIMAGETOOL_BIN`
- `LINUX_APPIMAGE_GPG_PASSPHRASE`
- `LINUX_APPIMAGE_UNSIGNED`
- `VIZOR_PRIVATE_USD_ENABLED`

## Unsigned AppImages

`LINUX_APPIMAGE_UNSIGNED=true` is the signing switch: `package` and `release`
then pass `--unsigned` to `scripts/package-linux-appimage.sh`, which writes the
AppImage and its `.sha256` with no embedded signature and no `.asc`, and the
lanes need no GPG key. It is for builds that publish nothing, such as Veylor's
CI on its fork (`.github/workflows/veylor-linux.yml`). A flavor or tag that
embeds update information refuses it, since updates must be verifiable. Unset
it, and provide the GPG variables above, to sign.

`VIZOR_PRIVATE_USD_ENABLED=true` compiles Shielded USD in (AGENTS.md, "Private
USD"). Its Railgun page runs in the bundle's `veylor-railgun-page`, on the
system's WebKitGTK 4.1 in WebKit's sandbox; where that can't start, Shielded USD
stays hidden (docs/private-usd-linux.md). The build needs
`libwebkit2gtk-4.1-dev` for the page process's headers; it never links WebKit,
and the AppImage carries none of it. Unset, the define is not passed.

`scripts/package-linux-deb.sh` packages a Veylor bundle as a .deb for Ubuntu
and Debian (`/opt/veylor` or `/opt/veylor-testnet`, with the AppArmor profile
the page's sandbox needs on Ubuntu 23.10 and later); Veylor's CI builds one
beside each AppImage.

## Asset names

mainnet:

- `Vizor-linux-x86_64.AppImage`
- `Vizor-linux-x86_64.AppImage.zsync`
- `Vizor-linux-x86_64.AppImage.sha256`
- `Vizor-linux-x86_64.AppImage.asc`
- `Vizor-linux-aarch64.AppImage`
- `Vizor-linux-aarch64.AppImage.zsync`
- `Vizor-linux-aarch64.AppImage.sha256`
- `Vizor-linux-aarch64.AppImage.asc`

testnet:

- `Vizor-Testnet-linux-x86_64.AppImage`
- `Vizor-Testnet-linux-x86_64.AppImage.zsync`
- `Vizor-Testnet-linux-x86_64.AppImage.sha256`
- `Vizor-Testnet-linux-x86_64.AppImage.asc`
- `Vizor-Testnet-linux-aarch64.AppImage`
- `Vizor-Testnet-linux-aarch64.AppImage.zsync`
- `Vizor-Testnet-linux-aarch64.AppImage.sha256`
- `Vizor-Testnet-linux-aarch64.AppImage.asc`

Stable AppImage update information uses GitHub Releases `latest` zsync entries
so stable AppImages can be updated by external AppImage update tools. Each
Linux CI job builds one native architecture by setting `VIZOR_LINUX_ARCH` to
`x86_64` or `aarch64`. Prerelease builds do not embed update information and do
not generate zsync assets.
