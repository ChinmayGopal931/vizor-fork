#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/veylor-android-release/install-toolchain.sh \
  --prefix DIR --accept-android-sdk-licenses

Installs the toolchain Veylor's verifiable APK is built with, at pinned
versions, under DIR, and writes DIR/env.sh to source before
scripts/build-android-reproducible.sh (docs/releases.md, "Android direct APK
(verifiable)"). The CI build and anyone rebuilding it use this script:

  - Temurin JDK 21.0.13+9 (SHA-256 pinned below)
  - Android command-line tools 19.0 (SHA-256 pinned below), then the SDK
    packages the build uses; sdkmanager checks them against Google's checksums
  - Flutter at scripts/release-config/flutter-sdk.json's version and commit
  - Rust at scripts/release-config/android-reproducible-rust-version.txt and
    its three Android targets, through rustup (which must be on PATH)

Linux x86_64 only. It needs curl, git, unzip, tar, sha256sum, python3 and a C
compiler (Debian and Ubuntu: build-essential). --accept-android-sdk-licenses
accepts the Android SDK's licenses for you; read them first with
`sdkmanager --licenses` if you have not. Flutter's settings stay in
DIR/config, so the build uses this JDK even beside Android Studio.
EOF
}

JDK_VERSION="21.0.13+9"
JDK_URL="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz"
JDK_SHA256="d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c"
CMDLINE_TOOLS_VERSION="19.0"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
CMDLINE_TOOLS_SHA256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"
# compileSdk 36 (the app and most plugins) and 33 (rust_builder's plugin);
# build-tools 36.0.0 (the app) and 35.0.0 (AGP 8.11's default for the plugin
# modules); the NDK android/app/build.gradle.kts pins.
ANDROID_BUILD_TOOLS="36.0.0"
ANDROID_NDK="28.2.13676358"
SDK_PACKAGES=(
  "platforms;android-36"
  "platforms;android-33"
  "build-tools;${ANDROID_BUILD_TOOLS}"
  "build-tools;35.0.0"
  "ndk;${ANDROID_NDK}"
)
RUST_TARGETS="aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android"
FLUTTER_GIT_URL="https://github.com/flutter/flutter.git"

prefix=""
accept_licenses="false"
while (($# > 0)); do
  case "$1" in
    --prefix)
      prefix="${2:-}"
      shift 2
      ;;
    --accept-android-sdk-licenses)
      accept_licenses="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() {
  echo "install-toolchain: $*" >&2
  exit 1
}

[[ -n "${prefix}" ]] || { usage >&2; exit 2; }
[[ "${accept_licenses}" == "true" ]] ||
  die "pass --accept-android-sdk-licenses to accept the Android SDK's licenses"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] ||
  die "the pinned toolchain is Linux x86_64 only"
for tool in curl git unzip tar sha256sum python3 cc rustup; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} is missing (rustup: https://rustup.rs)"
done
if [[ -e "${HOME}/.flutter_settings" ]]; then
  # Flutter reads a legacy ~/.flutter_settings before XDG_CONFIG_HOME, which
  # would bypass the toolchain's own JDK setting.
  die "move ${HOME}/.flutter_settings aside first: Flutter would read it instead of ${prefix}/config"
fi

mkdir -p -- "${prefix}"
prefix="$(cd -- "${prefix}" && pwd -P)"
# env.sh quotes the prefix in single quotes.
[[ "${prefix}" =~ ^/[A-Za-z0-9._/+-]+$ ]] ||
  die "the prefix may hold only letters, digits and ._/+-: ${prefix}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_dir}/../.." && pwd)"
read -r flutter_version flutter_revision < <(
  python3 -I - "${repository_root}" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pin = json.loads((root / "scripts/release-config/flutter-sdk.json").read_text())
fvmrc = json.loads((root / ".fvmrc").read_text())
if fvmrc["flutter"] != pin["version"]:
    sys.exit(".fvmrc and flutter-sdk.json pin different Flutter versions")
if not re.fullmatch(r"[0-9a-f]{40}", pin["revision"]):
    sys.exit("flutter-sdk.json must pin a full commit")
print(pin["version"], pin["revision"])
PY
)
[[ -n "${flutter_revision:-}" ]] || die "could not read the Flutter pin"
rust_toolchain="$("${repository_root}/scripts/run-with-android-reproducible-rust.sh" --print-toolchain)"

downloads="${prefix}/downloads"
logs="${prefix}/logs"
mkdir -p -- "${downloads}" "${logs}"

# fetch URL FILE SHA256
fetch() {
  local url="$1" file="$2" sha256="$3"
  if [[ ! -f "${file}" ]] || ! printf '%s  %s\n' "${sha256}" "${file}" | sha256sum --check --status; then
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "${file}.part" "${url}"
    mv -f -- "${file}.part" "${file}"
  fi
  printf '%s  %s\n' "${sha256}" "${file}" | sha256sum --check --quiet ||
    die "$(basename -- "${file}") does not match its pinned SHA-256"
}

java_home="${prefix}/jdk"
if ! grep -qs "^JAVA_RUNTIME_VERSION=\"${JDK_VERSION}" "${java_home}/release"; then
  echo "Installing Temurin ${JDK_VERSION}"
  archive="${downloads}/temurin-${JDK_VERSION}.tar.gz"
  fetch "${JDK_URL}" "${archive}" "${JDK_SHA256}"
  rm -rf -- "${java_home}"
  mkdir -p -- "${java_home}"
  tar -xzf "${archive}" -C "${java_home}" --strip-components=1
fi
"${java_home}/bin/java" -version 2>&1 | sed -n '1,2p'

# A package's source.properties may put spaces around '=' (the NDK's does).
package_revision() {
  sed -n 's/^Pkg\.Revision *= *//p' "$1/source.properties" 2>/dev/null | tr -d '\r' || true
}

android_home="${prefix}/android-sdk"
sdkmanager="${android_home}/cmdline-tools/latest/bin/sdkmanager"
if [[ "$(package_revision "${android_home}/cmdline-tools/latest")" != "${CMDLINE_TOOLS_VERSION}" ]]; then
  echo "Installing the Android command-line tools ${CMDLINE_TOOLS_VERSION}"
  archive="${downloads}/commandlinetools-${CMDLINE_TOOLS_VERSION}.zip"
  fetch "${CMDLINE_TOOLS_URL}" "${archive}" "${CMDLINE_TOOLS_SHA256}"
  rm -rf -- "${android_home}/cmdline-tools" "${downloads}/cmdline-tools"
  unzip -q "${archive}" -d "${downloads}"
  mkdir -p -- "${android_home}/cmdline-tools"
  mv -- "${downloads}/cmdline-tools" "${android_home}/cmdline-tools/latest"
fi
echo "Installing the Android SDK packages: ${SDK_PACKAGES[*]}"
# `yes` ends on SIGPIPE once sdkmanager stops reading.
{ yes 2>/dev/null || true; } |
  JAVA_HOME="${java_home}" "${sdkmanager}" --sdk_root="${android_home}" --licenses \
    >"${logs}/sdkmanager-licenses.log" 2>&1 ||
  die "sdkmanager --licenses failed (see ${logs}/sdkmanager-licenses.log)"
JAVA_HOME="${java_home}" "${sdkmanager}" --sdk_root="${android_home}" --install "${SDK_PACKAGES[@]}" \
  >"${logs}/sdkmanager-install.log" 2>&1 ||
  { tail -n 40 "${logs}/sdkmanager-install.log" >&2; die "sdkmanager --install failed"; }

flutter_root="${prefix}/flutter"
if [[ "$(git -C "${flutter_root}" rev-parse HEAD 2>/dev/null || true)" != "${flutter_revision}" ]]; then
  echo "Installing Flutter ${flutter_version}"
  rm -rf -- "${flutter_root}"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${flutter_version}" \
    "${FLUTTER_GIT_URL}" "${flutter_root}"
fi
actual_revision="$(git -C "${flutter_root}" rev-parse HEAD)"
[[ "${actual_revision}" == "${flutter_revision}" ]] ||
  die "Flutter ${flutter_version} is at ${actual_revision}, not the pinned ${flutter_revision}"
flutter_env=(env XDG_CONFIG_HOME="${prefix}/config" JAVA_HOME="${java_home}"
  ANDROID_HOME="${android_home}" ANDROID_SDK_ROOT="${android_home}")
"${flutter_env[@]}" "${flutter_root}/bin/flutter" --disable-analytics >/dev/null
"${flutter_env[@]}" "${flutter_root}/bin/flutter" config --no-analytics \
  --jdk-dir="${java_home}" --android-sdk="${android_home}" >/dev/null
"${flutter_env[@]}" "${flutter_root}/bin/flutter" --version

echo "Installing Rust ${rust_toolchain} for ${RUST_TARGETS}"
rustup toolchain install "${rust_toolchain}" --profile minimal --target "${RUST_TARGETS}"

cat >"${prefix}/env.sh" <<EOF
# Written by scripts/veylor-android-release/install-toolchain.sh; source it
# before scripts/build-android-reproducible.sh.
export VEYLOR_ANDROID_TOOLCHAIN='${prefix}'
export JAVA_HOME='${java_home}'
export ANDROID_HOME='${android_home}'
export ANDROID_SDK_ROOT='${android_home}'
# AGP and cargokit take the NDK from android/app/build.gradle.kts's ndkVersion.
unset ANDROID_NDK_HOME ANDROID_NDK_ROOT ANDROID_NDK ANDROID_NDK_LATEST_HOME
export FLUTTER_BIN='${flutter_root}/bin/flutter'
export XDG_CONFIG_HOME='${prefix}/config'
export RUSTUP_TOOLCHAIN='${rust_toolchain}'
export PATH='${java_home}/bin:${android_home}/build-tools/${ANDROID_BUILD_TOOLS}':"\${PATH}"
EOF

# What was installed, for the build's record.
{
  echo "jdk: $("${java_home}/bin/java" -version 2>&1 | sed -n '2p')"
  echo "android-cmdline-tools: ${CMDLINE_TOOLS_VERSION}"
  for package in "${SDK_PACKAGES[@]}"; do
    revision="$(package_revision "${android_home}/${package//;//}")"
    echo "android-sdk ${package}: ${revision:-?}"
  done
  echo "flutter: ${flutter_version} (${flutter_revision})"
  echo "dart: $("${flutter_root}/bin/cache/dart-sdk/bin/dart" --version 2>&1)"
  echo "rust: $(rustup run "${rust_toolchain}" rustc --version)"
} >"${prefix}/versions.txt"
cat "${prefix}/versions.txt"
echo "Next: . ${prefix}/env.sh"
