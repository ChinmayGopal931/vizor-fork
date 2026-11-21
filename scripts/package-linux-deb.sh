#!/usr/bin/env bash
set -euo pipefail

# Packages a Veylor Linux bundle as a .deb for Ubuntu and Debian (AGENTS.md,
# "Desktop identity"): the bundle under /opt/<package>, a /usr/bin link, the
# desktop entry and icons, and the AppArmor profile Shielded USD's page process
# needs on Ubuntu 23.10 and later, where WebKit's bubblewrap sandbox may create
# its user namespace only for programs a profile lets do so. The AppImage stays
# for other distributions; without this package's profile, Ubuntu hides
# Shielded USD rather than run the page outside the sandbox.

BUNDLE_DIR=""
OUTPUT_DIR=""
PACKAGE=""
APP_ID=""
APP_NAME=""
BINARY_NAME=""
VERSION=""
ARCH=""

usage() {
  cat <<USAGE
Usage: scripts/package-linux-deb.sh [options]

Required:
  --bundle-dir <path>     Flutter Linux bundle directory (dist/linux/<artifact>).
  --output-dir <path>     Where the .deb is written.
  --package <name>        Debian package name: veylor or veylor-testnet.
  --app-id <id>           Linux application id, e.g. com.veylor.desktop.
  --app-name <name>       Display name.
  --binary-name <name>    Executable name inside the bundle.
  --version <version>     Debian version, e.g. 0.9.0~internal.12.
  --arch <arch>           x86_64 or aarch64 (amd64 or arm64).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --app-id) APP_ID="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --binary-name) BINARY_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for required in BUNDLE_DIR OUTPUT_DIR PACKAGE APP_ID APP_NAME BINARY_NAME VERSION ARCH; do
  if [[ -z "${!required}" ]]; then
    echo "Missing --$(tr '[:upper:]_' '[:lower:]-' <<< "$required")" >&2
    usage >&2
    exit 2
  fi
done

case "$PACKAGE" in
  veylor|veylor-testnet) ;;
  *) echo "Unsupported package: $PACKAGE" >&2; exit 2 ;;
esac
case "$ARCH" in
  x86_64|amd64) DEB_ARCH="amd64" ;;
  aarch64|arm64) DEB_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;;
esac
if [[ ! "$VERSION" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]]; then
  echo "Not a Debian version: $VERSION" >&2
  exit 2
fi
for tool in dpkg-deb dpkg-shlibdeps readelf patchelf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool (dpkg-dev, binutils, patchelf)" >&2
    exit 1
  fi
done

BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
INSTALL_DIR="/opt/$PACKAGE"
RAILGUN_PAGE="veylor-railgun-page"

if [[ ! -x "$BUNDLE_DIR/$BINARY_NAME" ]]; then
  echo "Missing executable $BUNDLE_DIR/$BINARY_NAME" >&2
  exit 1
fi
if [[ ! -x "$BUNDLE_DIR/$RAILGUN_PAGE" ]]; then
  echo "Missing $BUNDLE_DIR/$RAILGUN_PAGE: build with libwebkit2gtk-4.1-dev installed" >&2
  exit 1
fi

WORK="$(mktemp -d "$OUTPUT_DIR/$PACKAGE.deb.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT$INSTALL_DIR" "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/DEBIAN" \
  "$ROOT/usr/share/$PACKAGE/apparmor"

cp -a "$BUNDLE_DIR/." "$ROOT$INSTALL_DIR/"
ln -s "$INSTALL_DIR/$BINARY_NAME" "$ROOT/usr/bin/$BINARY_NAME"
# What ZXing's own install leaves beside its library: headers and build files.
rm -rf "$ROOT$INSTALL_DIR/include" "$ROOT$INSTALL_DIR/lib/cmake" "$ROOT$INSTALL_DIR/lib/pkgconfig"

# The AppImage finds the bundle's libraries through AppRun's LD_LIBRARY_PATH; a
# package has none. The executable's RUNPATH ($ORIGIN/lib) reaches its own
# dependencies but not theirs, and the plugins keep the build tree's paths, so
# the QR scanner's plugin would not find ZXing beside it. Each bundled library
# that has a library path, or needs another bundled library, looks beside
# itself instead.
lib_dir="$ROOT$INSTALL_DIR/lib"
for library in "$lib_dir"/*.so*; do
  [[ -f "$library" && ! -L "$library" ]] || continue
  dynamic="$(readelf --wide --dynamic "$library" 2>/dev/null || true)"
  needs_bundled="false"
  while IFS= read -r needed; do
    if [[ -n "$needed" && -e "$lib_dir/$needed" ]]; then
      needs_bundled="true"
    fi
  done < <(sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' <<< "$dynamic")
  if [[ "$needs_bundled" == "true" ]] || grep -qE '\((RPATH|RUNPATH)\)' <<< "$dynamic"; then
    patchelf --set-rpath '$ORIGIN' "$library"
  fi
done

desktop="$ROOT/usr/share/applications/$APP_ID.desktop"
cp "$BUNDLE_DIR/data/applications/$APP_ID.desktop" "$desktop"
sed -i -e "s|^Exec=.*|Exec=$BINARY_NAME %u|" -e "s|^Icon=.*|Icon=$APP_ID|" "$desktop"
grep -q "^TryExec=" "$desktop" || sed -i -e "/^Exec=/a TryExec=$BINARY_NAME" "$desktop"
for size_dir in "$BUNDLE_DIR"/data/icons/hicolor/*/apps; do
  size="$(basename "$(dirname "$size_dir")")"
  mkdir -p "$ROOT/usr/share/icons/hicolor/$size/apps"
  cp "$size_dir/$APP_ID.png" "$ROOT/usr/share/icons/hicolor/$size/apps/$APP_ID.png"
done

# The profile Ubuntu's own WebKitGTK apps have (Epiphany's, for one): it allows
# everything and exists to let bubblewrap make its user namespace. It is for the
# page process alone, at this package's fixed, root-owned path.
PROFILE_NAME="$PACKAGE"
cat > "$ROOT/usr/share/$PACKAGE/apparmor/$PROFILE_NAME" <<PROFILE
# Lets WebKit's bubblewrap sandbox, in which $APP_NAME's Shielded USD page runs,
# create its user namespace: Ubuntu 23.10 and later refuse that to programs no
# AppArmor profile allows it. It allows everything else, as Ubuntu's profiles
# for Epiphany and other WebKitGTK apps do, and confines nothing.

abi <abi/4.0>,
include <tunables/global>

profile $PACKAGE-railgun-page $INSTALL_DIR/$RAILGUN_PAGE flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/$PROFILE_NAME>
}
PROFILE

# The maintainer scripts. The profile needs AppArmor 4's \`userns\` rule, which
# AppArmor 3 (Ubuntu 22.04, Debian 12) can't parse and doesn't need, so it is
# put in place only where AppArmor knows the rule; dpkg doesn't own it.
cat > "$ROOT/DEBIAN/postinst" <<SCRIPT
#!/bin/sh
set -e
profile="/etc/apparmor.d/$PROFILE_NAME"
template="/usr/share/$PACKAGE/apparmor/$PROFILE_NAME"
if [ "\$1" = "configure" ] && [ -f /etc/apparmor.d/abi/4.0 ]; then
  install -m 644 "\$template" "\$profile"
  mkdir -p /etc/apparmor.d/local
  [ -e "/etc/apparmor.d/local/$PROFILE_NAME" ] || install -m 644 /dev/null "/etc/apparmor.d/local/$PROFILE_NAME"
  if command -v apparmor_parser >/dev/null 2>&1 && aa-enabled --quiet 2>/dev/null; then
    apparmor_parser -r -T -W "\$profile" ||
      echo "$PACKAGE: the AppArmor profile did not load; Shielded USD stays hidden until it does" >&2
  fi
fi
exit 0
SCRIPT

cat > "$ROOT/DEBIAN/prerm" <<SCRIPT
#!/bin/sh
set -e
profile="/etc/apparmor.d/$PROFILE_NAME"
if [ "\$1" = "remove" ] && [ -f "\$profile" ] && command -v apparmor_parser >/dev/null 2>&1; then
  apparmor_parser -R "\$profile" >/dev/null 2>&1 || true
fi
exit 0
SCRIPT

cat > "$ROOT/DEBIAN/postrm" <<SCRIPT
#!/bin/sh
set -e
case "\$1" in
  remove|purge)
    rm -f "/etc/apparmor.d/$PROFILE_NAME"
    rm -f /var/cache/apparmor/*/"$PROFILE_NAME" 2>/dev/null || true
    ;;
esac
if [ "\$1" = "purge" ]; then
  rm -f "/etc/apparmor.d/local/$PROFILE_NAME"
fi
exit 0
SCRIPT
chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/DEBIAN/postrm"

# Depends from the libraries the bundle's programs link, as the build host's
# packages name them; the bundle's own lib/ holds private libraries.
mkdir -p "$WORK/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$PACKAGE" "$PACKAGE" > "$WORK/shlibs/debian/control"
elf_files=()
while IFS= read -r -d '' file; do
  if [[ "$(head -c 4 "$file" | od -An -c | tr -d ' ')" == "177ELF" ]]; then
    elf_files+=("$file")
  fi
done < <(find "$ROOT$INSTALL_DIR" -type f -print0)
depends="$(
  cd "$WORK/shlibs" &&
    dpkg-shlibdeps -O --ignore-missing-info -l"$ROOT$INSTALL_DIR/lib" "${elf_files[@]}" 2>"$WORK/shlibdeps.log" |
    sed -n 's/^shlibs:Depends=//p'
)"
if [[ -z "$depends" ]]; then
  echo "dpkg-shlibdeps found no dependencies:" >&2
  cat "$WORK/shlibdeps.log" >&2
  exit 1
fi

installed_size="$(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)"
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: $PACKAGE
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Zapp LLC <hello@veylor.cash>
Installed-Size: $installed_size
Depends: $depends
Recommends: libwebkit2gtk-4.1-0, gnome-keyring | kwalletmanager | keepassxc, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-pipewire
Section: utils
Priority: optional
Homepage: https://github.com/ChinmayGopal931/vizor-fork
Description: $APP_NAME, a self-custody Zcash wallet
 $APP_NAME keeps a Zcash wallet on this computer, with shielded payments,
 swaps and Shielded USD. Shielded USD needs WebKitGTK 4.1 (recommended);
 without it the app runs with Shielded USD hidden. A Secret Service provider
 holds the wallet's keys, and GStreamer's plugins scan QR codes.
CONTROL

find "$ROOT" -type d -exec chmod 0755 {} +
chmod -R go-w "$ROOT"
output="$OUTPUT_DIR/${PACKAGE}_${VERSION}_${DEB_ARCH}.deb"
rm -f "$output"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$output" >/dev/null

# The package as built: its control, its scripts and where its files go.
dpkg-deb --field "$output" Package Version Architecture Depends Recommends
dpkg-deb --contents "$output" | awk '{ $1 = $2 = $3 = $4 = $5 = ""; sub(/^ +/, ""); print }' |
  grep -E "(/usr/bin/.|/usr/share/applications/.|/apparmor/.|/$RAILGUN_PAGE$|/data/railgun/index.html$)"
echo "Debian package written to $output"
