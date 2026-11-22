#!/usr/bin/env bash
# Veylor's macOS release (docs/releases.md, "Veylor macOS release"). It builds the
# app with Veylor's identity, signs it with Zapp LLC's Developer ID,
# notarizes and staples it, packages Veylor-macos.dmg, signs, notarizes and
# staples that, and writes the signed Sparkle appcast, leaving the assets in
# one folder. It publishes nothing.
#
#   scripts/release-veylor-macos.sh --version 0.9.0 --build-number 1
#
# If it stops while Apple is still notarizing (a new team's first
# submissions can take hours), run the same command with --resume: it keeps
# the signed app and DMG and waits on the same submissions.
#
# It needs Zapp LLC's Developer ID identity and the "Veylor Desktop Developer
# ID" profile, the App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_FILEPATH, from the environment or ~/dev/zapp/ios-zapp/fastlane/.env),
# Veylor's Sparkle key (its backup file or the login Keychain), fvm, and
# Python 3.10 or later. The build goes to build/veylor-release, so a Veylor
# running from build/macos keeps its bundle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Veylor's release identity. Upstream's team never signs a Veylor release.
VEYLOR_TEAM_ID="63UVRFCV97"
UPSTREAM_TEAM_ID="SZTB68DXM4"
BUNDLE_ID="com.veylor.desktop"
APP_NAME="Veylor"
APP_ICON_FILE="VeylorAppIcon"
SIGNING_IDENTITY="Developer ID Application: Zapp LLC (${VEYLOR_TEAM_ID})"
PROFILE_NAME="Veylor Desktop Developer ID"

# Updates: GitHub Releases on the fork, verified with Veylor's EdDSA key.
RELEASE_REPOSITORY="ChinmayGopal931/vizor-fork"
SPARKLE_FEED_URL="https://github.com/${RELEASE_REPOSITORY}/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="25Gjp3M2h14oTrfaBpmobsrqF+92J7yOo0X7QP+GvSE="
SPARKLE_KEY_ACCOUNT="veylor-desktop"
SPARKLE_DEFAULT_KEY_FILE="$HOME/keys/veylor/sparkle/veylor-desktop-sparkle-ed25519.key"

# Release assets. The DMG's name never carries the version: the website links
# to releases/latest/download/Veylor-macos.dmg.
DMG_ASSET="Veylor-macos.dmg"
NOTES_ASSET="Veylor-macos.md"
APPCAST_ASSET="appcast.xml"
VOLUME_NAME="Veylor"

VERSION=""
BUILD_NUMBER=""
TAG=""
NOTES_PATH=""
OUT_DIR=""
SPARKLE_KEY_FILE=""
NOTARY_ENV_FILE="${VEYLOR_NOTARY_ENV_FILE:-$HOME/dev/zapp/ios-zapp/fastlane/.env}"
SKIP_BUILD=false
ALLOW_DIRTY=false
RESUME=false
# How long to wait on Apple; a new team's first submissions can take hours.
NOTARY_TIMEOUT="${VEYLOR_NOTARY_TIMEOUT:-12h}"

usage() {
  cat <<USAGE
Usage: scripts/release-veylor-macos.sh --version X.Y.Z --build-number N [options]

  --version X.Y.Z          The version users see (CFBundleShortVersionString).
  --build-number N         CFBundleVersion and sparkle:version; above every
                           earlier release's.
  --tag TAG                The GitHub release tag the assets go under
                           (default: veylor-macos/vX.Y.Z).
  --notes FILE             Release notes (default:
                           release_notes/veylor-macos-vX.Y.Z.md).
  --output DIR             Where the assets go (default:
                           dist/veylor-macos/vX.Y.Z).
  --sparkle-key-file FILE  Veylor's Sparkle private key file (default:
                           ~/keys/veylor/sparkle/veylor-desktop-sparkle-ed25519.key
                           if present, else the login Keychain's
                           "$SPARKLE_KEY_ACCOUNT" account).
  --notary-env FILE        The .env with ASC_KEY_ID, ASC_ISSUER_ID and
                           ASC_KEY_FILEPATH, used in place (default:
                           ~/dev/zapp/ios-zapp/fastlane/.env). The three
                           variables in the environment win.
  --skip-build             Reuse build/veylor-release's last build of this
                           version and build number.
  --resume                 Pick up a run that stopped (Apple still
                           notarizing, a closed terminal): keep its build,
                           its signed app and DMG and its notary
                           submissions, and wait for those rather than
                           sign and submit again.
  --allow-dirty            Build a tree with uncommitted changes (never for a
                           release that ships).

Apple's answer is awaited for up to VEYLOR_NOTARY_TIMEOUT (default 12h).
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '\nrelease-veylor-macos: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --notes) NOTES_PATH="${2:-}"; shift 2 ;;
    --output) OUT_DIR="${2:-}"; shift 2 ;;
    --sparkle-key-file) SPARKLE_KEY_FILE="${2:-}"; shift 2 ;;
    --notary-env) NOTARY_ENV_FILE="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --resume) RESUME=true; SKIP_BUILD=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage >&2; die "--version must look like 0.9.0"; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { usage >&2; die "--build-number must be a positive integer"; }
TAG="${TAG:-veylor-macos/v$VERSION}"
NOTES_PATH="${NOTES_PATH:-$ROOT_DIR/release_notes/veylor-macos-v$VERSION.md}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/veylor-macos/v$VERSION}"
[[ "$TAG" =~ ^[A-Za-z0-9._/-]+$ ]] || die "the tag may hold only letters, digits, '.', '_', '-' and '/'"

RELEASE_PAGE_URL="https://github.com/${RELEASE_REPOSITORY}/releases/tag/${TAG}"
DOWNLOAD_PREFIX="https://github.com/${RELEASE_REPOSITORY}/releases/download/${TAG}/"
DMG_URL="${DOWNLOAD_PREFIX}${DMG_ASSET}"
NOTES_URL="${DOWNLOAD_PREFIX}${NOTES_ASSET}"

BUILD_ROOT="$ROOT_DIR/build/veylor-release"
PRODUCTS_DIR="$BUILD_ROOT/Products"
BUILT_APP="$PRODUCTS_DIR/Release/$APP_NAME.app"
# The commit the last build came from, for a run that reuses it.
BUILD_COMMIT_FILE="$BUILD_ROOT/build-commit"
WORK_DIR="$BUILD_ROOT/work"
STAGED_APP="$WORK_DIR/stage/$APP_NAME.app"
TOOLS_VENV="$BUILD_ROOT/tools/venv"
LOG_DIR="$OUT_DIR/logs"
SPARKLE_BIN="$ROOT_DIR/build/macos/SourcePackages/artifacts/sparkle/Sparkle/bin"
OVERRIDES_PATH="$ROOT_DIR/macos/Runner/Configs/FlavorOverrides.xcconfig"
OVERRIDES_BACKUP=""
OVERRIDES_SELECTED=false
PODFILE_LOCK="$ROOT_DIR/macos/Podfile.lock"
PODFILE_LOCK_BACKUP=""

restore_overrides() {
  [[ "$OVERRIDES_SELECTED" == true ]] || return 0
  if [[ -n "$OVERRIDES_BACKUP" ]]; then
    mv -f "$OVERRIDES_BACKUP" "$OVERRIDES_PATH"
  else
    rm -f "$OVERRIDES_PATH"
  fi
  OVERRIDES_SELECTED=false
}

# pod install, which the build runs, rewrites Podfile.lock's COCOAPODS line
# with the local CocoaPods version. Put it back when that is all it changed;
# the next build's pod install brings the Pods back in step.
restore_podfile_lock() {
  [[ -n "$PODFILE_LOCK_BACKUP" ]] || return 0
  if ! cmp -s "$PODFILE_LOCK" "$PODFILE_LOCK_BACKUP"; then
    if diff <(grep -v '^COCOAPODS:' "$PODFILE_LOCK") <(grep -v '^COCOAPODS:' "$PODFILE_LOCK_BACKUP") >/dev/null; then
      cp "$PODFILE_LOCK_BACKUP" "$PODFILE_LOCK"
    else
      note "pod install changed macos/Podfile.lock beyond its COCOAPODS line; review it"
    fi
  fi
  rm -f "$PODFILE_LOCK_BACKUP"
  PODFILE_LOCK_BACKUP=""
}

cleanup() {
  restore_overrides
  restore_podfile_lock
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# Reads KEY from a dotenv file without evaluating it.
dotenv_value() {
  local line value
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1" | tail -n 1 || true)"
  value="${line#*=}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$value"
}

# The first Python 3.10 or later, which dmgbuild needs.
find_python() {
  local candidate
  for candidate in "${VEYLOR_PYTHON:-}" python3.13 python3.12 python3.11 python3.10 python3; do
    [[ -n "$candidate" ]] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

# Signs with Veylor's Developer ID for distribution: hardened runtime and a
# secure timestamp, as notarization needs.
codesign_for_distribution() {
  local path="$1" preserve="${2:-}"
  local command=(/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
  [[ -z "$preserve" ]] || command+=("--preserve-metadata=$preserve")
  "${command[@]}" "$path"
}

# Fails unless PATH carries Veylor's Developer ID signature with a secure
# timestamp.
check_signature() {
  local path="$1" details
  details="$(/usr/bin/codesign -dvv "$path" 2>&1)" || die "$path is not signed"
  grep -q "^Authority=${SIGNING_IDENTITY}$" <<<"$details" ||
    die "$path is not signed by $SIGNING_IDENTITY"
  grep -q "^TeamIdentifier=${VEYLOR_TEAM_ID}$" <<<"$details" ||
    die "$path is not signed with team $VEYLOR_TEAM_ID"
  grep -q "^Timestamp=" <<<"$details" || die "$path has no secure timestamp"
  if grep -q "$UPSTREAM_TEAM_ID" <<<"$details"; then
    die "$path carries upstream's team $UPSTREAM_TEAM_ID"
  fi
}

# Every binary and bundle inside the app, nested first.
nested_code() {
  local app="$1"
  find "$app/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) -prune -print 2>/dev/null
  find "$app/Contents/Frameworks" -path '*/Versions/*/XPCServices/*.xpc' -prune -print 2>/dev/null
  find "$app/Contents/Frameworks" -path '*/Versions/*/Updater.app' -prune -print 2>/dev/null
  find "$app/Contents/Frameworks" -path '*/Versions/*/Autoupdate' -type f -print 2>/dev/null
}

# Submits PATH, or with --resume waits on the submission an earlier run made,
# whose id the work folder keeps.
notarize() {
  local path="$1" label="$2" id_file="$WORK_DIR/notary-$2.id"
  local status id
  if [[ "$RESUME" == true && -s "$id_file" ]]; then
    id="$(cat "$id_file")"
    note "waiting on the earlier submission $id"
  else
    note "submitting $(basename "$path") to Apple's notary service"
    xcrun notarytool submit "$path" "${NOTARY_AUTH[@]}" --output-format json \
      >"$LOG_DIR/notary-$label-submit.json" 2>"$LOG_DIR/notary-$label-submit.err" ||
      die "notarytool could not submit $label (see $LOG_DIR/notary-$label-submit.err)"
    id="$(/usr/bin/plutil -extract id raw -o - "$LOG_DIR/notary-$label-submit.json" 2>/dev/null || true)"
    [[ -n "$id" ]] || die "notarytool returned no submission id for $label"
    printf '%s\n' "$id" >"$id_file"
    note "submission $id; waiting up to $NOTARY_TIMEOUT (a new team's first ones can take hours)"
  fi
  # wait exits non-zero on a timeout and for a rejected submission; info says which.
  xcrun notarytool wait "$id" "${NOTARY_AUTH[@]}" --timeout "$NOTARY_TIMEOUT" \
    >"$LOG_DIR/notary-$label-wait.log" 2>&1 || true
  xcrun notarytool info "$id" "${NOTARY_AUTH[@]}" --output-format json \
    >"$LOG_DIR/notary-$label-info.json" 2>/dev/null || true
  status="$(/usr/bin/plutil -extract status raw -o - "$LOG_DIR/notary-$label-info.json" 2>/dev/null || true)"
  if [[ "$status" == "In Progress" || -z "$status" ]]; then
    die "Apple has not finished notarizing $label ($id). Run the same command with --resume to wait again."
  fi
  xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" "$LOG_DIR/notary-$label-log.json" >/dev/null 2>&1 ||
    note "could not fetch the notary log for $id"
  note "notarization $id: $status"
  if [[ -f "$LOG_DIR/notary-$label-log.json" ]]; then
    "$PYTHON" -I - "$LOG_DIR/notary-$label-log.json" <<'PY'
import json, sys
log = json.load(open(sys.argv[1]))
issues = log.get("issues") or []
print(f"    notary log: {log.get('status')}, {len(issues)} issue(s)")
for issue in issues[:20]:
    print(f"      {issue.get('severity')}: {issue.get('path')}: {issue.get('message')}")
PY
  fi
  [[ "$status" == "Accepted" ]] || die "Apple did not accept $label ($status); see $LOG_DIR"
  NOTARY_IDS+=("$label=$id")
}

sparkle_tool() {
  local tool="$SPARKLE_BIN/$1"
  shift
  [[ -x "$tool" ]] || die "Sparkle's $(basename "$tool") is missing from $SPARKLE_BIN; resolve the Swift packages with a macOS build first"
  "$tool" "$@"
}

# ---------------------------------------------------------------------------
log "Checking the release inputs"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS releases build on macOS"
for tool in fvm xcrun ditto hdiutil shasum git security; do require "$tool"; done
PYTHON="$(find_python)" || die "Python 3.10 or later is required (set VEYLOR_PYTHON)"
[[ -f "$NOTES_PATH" ]] || die "missing release notes: $NOTES_PATH"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  note "a $APP_NAME is running; the release builds into build/veylor-release and leaves it alone"
fi

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
  [[ "$ALLOW_DIRTY" == true ]] || die "the tree has uncommitted changes; commit them or pass --allow-dirty (never for a release that ships)"
  note "building a tree with uncommitted changes (--allow-dirty)"
fi
note "commit $COMMIT, version $VERSION ($BUILD_NUMBER), tag $TAG"

# The signing identity must be Zapp LLC's, never upstream's.
[[ "$SIGNING_IDENTITY" == *"(${VEYLOR_TEAM_ID})" ]] || die "refusing to sign with $SIGNING_IDENTITY"
[[ "$SIGNING_IDENTITY" != *"$UPSTREAM_TEAM_ID"* ]] || die "refusing to sign with upstream's team"
# Checks read captured output: `producer | grep -q` fails under pipefail
# when grep stops reading early.
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -Fq "\"$SIGNING_IDENTITY\"" <<<"$IDENTITIES" ||
  die "the signing identity \"$SIGNING_IDENTITY\" is not in the keychain"

# The Developer ID profile Xcode signs the app with.
PROFILE_PATH=""
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [[ -d "$dir" ]] || continue
  for candidate in "$dir"/*.provisionprofile; do
    [[ -f "$candidate" ]] || continue
    decoded="$(mktemp -t veylor-profile)"
    if security cms -D -i "$candidate" >"$decoded" 2>/dev/null &&
      [[ "$(plist_value "$decoded" Name)" == "$PROFILE_NAME" ]]; then
      [[ "$(plist_value "$decoded" TeamIdentifier:0)" == "$VEYLOR_TEAM_ID" ]] || die "$PROFILE_NAME belongs to another team"
      [[ "$(plist_value "$decoded" Entitlements:com.apple.application-identifier)" == "$VEYLOR_TEAM_ID.$BUNDLE_ID" ]] ||
        die "$PROFILE_NAME is not for $BUNDLE_ID"
      [[ "$(plist_value "$decoded" ProvisionsAllDevices)" == "true" ]] || die "$PROFILE_NAME is not a Developer ID profile"
      PROFILE_PATH="$candidate"
    fi
    rm -f "$decoded"
  done
done
[[ -n "$PROFILE_PATH" ]] || die "the \"$PROFILE_NAME\" profile is not installed"
note "profile: $PROFILE_NAME ($(basename "$PROFILE_PATH"))"

# Notary credentials, used in place and never printed.
ASC_KEY_ID_VALUE="${ASC_KEY_ID:-}"
ASC_ISSUER_ID_VALUE="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_FILEPATH:-}"
if [[ -z "$ASC_KEY_ID_VALUE" || -z "$ASC_ISSUER_ID_VALUE" || -z "$ASC_KEY_PATH" ]]; then
  [[ -f "$NOTARY_ENV_FILE" ]] || die "no App Store Connect key: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_FILEPATH, or pass --notary-env"
  ASC_KEY_ID_VALUE="$(dotenv_value "$NOTARY_ENV_FILE" ASC_KEY_ID)"
  ASC_ISSUER_ID_VALUE="$(dotenv_value "$NOTARY_ENV_FILE" ASC_ISSUER_ID)"
  ASC_KEY_PATH="$(dotenv_value "$NOTARY_ENV_FILE" ASC_KEY_FILEPATH)"
  # A relative key path is relative to the .env, as fastlane reads it there.
  if [[ -n "$ASC_KEY_PATH" && "$ASC_KEY_PATH" != /* ]]; then
    ASC_KEY_PATH="$(cd "$(dirname "$NOTARY_ENV_FILE")" && pwd)/$ASC_KEY_PATH"
  fi
fi
[[ -n "$ASC_KEY_ID_VALUE" && -n "$ASC_ISSUER_ID_VALUE" ]] || die "ASC_KEY_ID and ASC_ISSUER_ID are required"
[[ -r "$ASC_KEY_PATH" ]] || die "the App Store Connect key file is not readable"
NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID_VALUE" --issuer "$ASC_ISSUER_ID_VALUE")
note "notary key: found (not printed)"

# Veylor's Sparkle key: the backup file, else the login Keychain.
if [[ -z "$SPARKLE_KEY_FILE" && -f "$SPARKLE_DEFAULT_KEY_FILE" ]]; then
  SPARKLE_KEY_FILE="$SPARKLE_DEFAULT_KEY_FILE"
fi
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
  [[ -r "$SPARKLE_KEY_FILE" ]] || die "cannot read the Sparkle key file $SPARKLE_KEY_FILE"
  [[ "$(stat -f '%Lp' "$SPARKLE_KEY_FILE")" == "600" ]] || die "the Sparkle key file must have mode 600"
  SPARKLE_KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
  note "Sparkle key: $SPARKLE_KEY_FILE"
else
  security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_KEY_ACCOUNT" >/dev/null 2>&1 ||
    die "no Sparkle key: pass --sparkle-key-file or add the $SPARKLE_KEY_ACCOUNT account with generate_keys"
  SPARKLE_KEY_ARGS=(--account "$SPARKLE_KEY_ACCOUNT")
  note "Sparkle key: login Keychain, account $SPARKLE_KEY_ACCOUNT"
fi

if [[ "$RESUME" == true ]]; then
  # A stopped run leaves its logs; a finished one, its DMG.
  [[ -d "$STAGED_APP" ]] || die "no stopped run to resume: $STAGED_APP is missing"
  [[ ! -e "$OUT_DIR/$DMG_ASSET" ]] || die "$OUT_DIR already holds a finished release"
  note "resuming the run in $WORK_DIR"
elif [[ -d "$OUT_DIR" && -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
  die "$OUT_DIR is not empty; move it away first"
fi
mkdir -p "$OUT_DIR" "$LOG_DIR"
NOTARY_IDS=()

FREE_GB="$(df -g "$ROOT_DIR" | awk 'NR == 2 { print $4 }')"
[[ "${FREE_GB:-0}" -ge 6 ]] || die "only ${FREE_GB} GB free; the release needs about 6 GB"

# ---------------------------------------------------------------------------
DART_DEFINES=(
  "ZCASH_DEFAULT_NETWORK=main"
  "VIZOR_RELEASE_VERSION=$VERSION"
  "VIZOR_RELEASE_REPOSITORY=$RELEASE_REPOSITORY"
  "VIZOR_COINGECKO_PRICE_BASE_URL=${VIZOR_COINGECKO_PRICE_BASE_URL:-https://api.coingecko.com/api/v3}"
  "VIZOR_WALLET_LINK_BACKEND_URL=${VIZOR_WALLET_LINK_BACKEND_URL:-https://functions.vizor.cash}"
  "VIZOR_PRIVATE_USD_ENABLED=true"
)
# Shielded USD's kill switch, from the one file every Veylor pipeline reads
# (docs/releases.md); none while it names none.
FLAG_URL="$("$ROOT_DIR/scripts/veylor-private-usd-flag-url.sh")" ||
  die "scripts/release-config/veylor-private-usd-flag-url.txt does not hold a usable URL"
if [[ -n "$FLAG_URL" ]]; then
  DART_DEFINES+=("VIZOR_PRIVATE_USD_FLAG_URL=$FLAG_URL")
fi

if [[ "$SKIP_BUILD" == true ]]; then
  log "Reusing the last build"
  [[ -d "$BUILT_APP" ]] || die "no earlier build at $BUILT_APP"
  BUILD_COMMIT="$(cat "$BUILD_COMMIT_FILE" 2>/dev/null || true)"
  [[ -n "$BUILD_COMMIT" ]] || die "the last build did not record its commit; build again"
  note "built from $BUILD_COMMIT"
else
  log "Building $APP_NAME $VERSION ($BUILD_NUMBER) for mainnet"
  if [[ -f "$OVERRIDES_PATH" ]]; then
    OVERRIDES_BACKUP="$(mktemp -t veylor-flavor-overrides)"
    cp "$OVERRIDES_PATH" "$OVERRIDES_BACKUP"
  fi
  OVERRIDES_SELECTED=true
  "$ROOT_DIR/scripts/macos-identity.sh" "$BUNDLE_ID" --release
  PODFILE_LOCK_BACKUP="$(mktemp -t veylor-podfile-lock)"
  cp "$PODFILE_LOCK" "$PODFILE_LOCK_BACKUP"

  (cd "$ROOT_DIR" && fvm flutter pub get >"$LOG_DIR/pub-get.log" 2>&1) || die "flutter pub get failed (see $LOG_DIR/pub-get.log)"
  flutter_args=(build macos --release --config-only --no-pub --build-name "$VERSION" --build-number "$BUILD_NUMBER")
  for define in "${DART_DEFINES[@]}"; do flutter_args+=("--dart-define=$define"); done
  (cd "$ROOT_DIR" && fvm flutter "${flutter_args[@]}" >"$LOG_DIR/flutter-config.log" 2>&1) ||
    die "flutter build macos --config-only failed (see $LOG_DIR/flutter-config.log)"

  # The generated config must carry exactly these defines besides Flutter's
  # own FLUTTER_* ones: no keyed RPC URL, nothing from an earlier build.
  GENERATED="$ROOT_DIR/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
  "$PYTHON" -I - "$GENERATED" "$VERSION" "$BUILD_NUMBER" "${DART_DEFINES[@]}" <<'PY' || die "the generated Flutter config does not match the release"
import base64, sys
path, version, build, *expected = sys.argv[1:]
settings = {}
for line in open(path, encoding="utf-8"):
    key, sep, value = line.strip().partition("=")
    if sep:
        settings[key] = value
defines = [base64.b64decode(item).decode() for item in settings.get("DART_DEFINES", "").split(",") if item]
ours = sorted(d for d in defines if not d.startswith("FLUTTER_"))
if ours != sorted(expected):
    # Print the keys only: a stray value could be a keyed URL.
    sys.exit("unexpected dart-defines: " + ", ".join(d.split("=", 1)[0] for d in ours))
flutter = dict(d.split("=", 1) for d in defines if d.startswith("FLUTTER_"))
for source in (settings, flutter):
    if source.get("FLUTTER_BUILD_NAME") != version or source.get("FLUTTER_BUILD_NUMBER") != build:
        sys.exit("unexpected build name or number")
PY

  note "xcodebuild (several minutes; log: $LOG_DIR/xcodebuild.log)"
  rm -rf "$PRODUCTS_DIR" "$BUILD_COMMIT_FILE"
  (cd "$ROOT_DIR" && xcrun xcodebuild \
    -clonedSourcePackagesDirPath "$ROOT_DIR/build/macos/SourcePackages" \
    -workspace "$ROOT_DIR/macos/Runner.xcworkspace" \
    -scheme Runner \
    -configuration Release \
    -derivedDataPath "$ROOT_DIR/build/macos" \
    -destination "generic/platform=macOS" \
    OBJROOT="$ROOT_DIR/build/macos/Build/Intermediates.noindex" \
    SYMROOT="$PRODUCTS_DIR" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build >"$LOG_DIR/xcodebuild.log" 2>&1) || {
    grep -E "error:|BUILD FAILED" "$LOG_DIR/xcodebuild.log" | tail -n 30 >&2 || true
    die "xcodebuild failed (see $LOG_DIR/xcodebuild.log)"
  }
  restore_overrides
  restore_podfile_lock
  BUILD_COMMIT="$COMMIT"
  printf '%s\n' "$BUILD_COMMIT" >"$BUILD_COMMIT_FILE"
fi

# ---------------------------------------------------------------------------
log "Checking the built app"

[[ -d "$BUILT_APP" ]] || die "no app at $BUILT_APP"
INFO_PLIST="$BUILT_APP/Contents/Info.plist"
[[ "$(plist_value "$INFO_PLIST" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "the bundle id is not $BUNDLE_ID"
[[ "$(plist_value "$INFO_PLIST" CFBundleName)" == "$APP_NAME" ]] || die "the bundle name is not $APP_NAME"
[[ "$(plist_value "$INFO_PLIST" CFBundleIconFile)" == "$APP_ICON_FILE" ]] || die "the icon is not $APP_ICON_FILE"
[[ "$(plist_value "$INFO_PLIST" CFBundleShortVersionString)" == "$VERSION" ]] || die "the version is not $VERSION"
[[ "$(plist_value "$INFO_PLIST" CFBundleVersion)" == "$BUILD_NUMBER" ]] || die "the build number is not $BUILD_NUMBER"
MINIMUM_SYSTEM_VERSION="$(plist_value "$INFO_PLIST" LSMinimumSystemVersion)"
[[ -n "$MINIMUM_SYSTEM_VERSION" ]] || die "the app has no LSMinimumSystemVersion"
# Sparkle must be compiled in: the app references its updater controller.
UNDEFINED_SYMBOLS="$(nm -u "$BUILT_APP/Contents/MacOS/$APP_NAME" 2>/dev/null)"
grep -q "SPUStandardUpdaterController" <<<"$UNDEFINED_SYMBOLS" ||
  die "Sparkle is not compiled in (SPARKLE_ENABLED)"
note "$BUNDLE_ID $VERSION ($BUILD_NUMBER), macOS $MINIMUM_SYSTEM_VERSION or later, Sparkle compiled in"

# ---------------------------------------------------------------------------
STAGED_INFO="$STAGED_APP/Contents/Info.plist"
if [[ "$RESUME" == true ]]; then
  # The stopped run's signed app; signing it again would void its submission.
  log "Keeping the stopped run's signed app"
else
  log "Staging the app with Sparkle's feed and key"
  rm -rf "$WORK_DIR"
  mkdir -p "$(dirname "$STAGED_APP")"
  ditto "$BUILT_APP" "$STAGED_APP"
  /usr/bin/plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$STAGED_INFO"
  /usr/bin/plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL" "$STAGED_INFO"
  /usr/bin/plutil -replace SUVerifyUpdateBeforeExtraction -bool YES "$STAGED_INFO"
  /usr/bin/plutil -replace SURequireSignedFeed -bool YES "$STAGED_INFO"
  /usr/bin/plutil -replace SUSignedFeedFailureExpirationInterval -integer 0 "$STAGED_INFO"

  # Sparkle's helpers ship with Sparkle's own signatures; they and the app are
  # signed again, nested first, as upstream's release lane does.
  log "Signing with $SIGNING_IDENTITY"
  SPARKLE_VERSION_DIR="$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  [[ -d "$SPARKLE_VERSION_DIR" ]] || die "Sparkle.framework is missing from the app"
  codesign_for_distribution "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  codesign_for_distribution "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" entitlements
  codesign_for_distribution "$SPARKLE_VERSION_DIR/Autoupdate"
  codesign_for_distribution "$SPARKLE_VERSION_DIR/Updater.app"
  codesign_for_distribution "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
  codesign_for_distribution "$STAGED_APP" identifier,entitlements
fi

[[ "$(plist_value "$STAGED_INFO" SUFeedURL)" == "$SPARKLE_FEED_URL" ]] || die "the app's SUFeedURL is not $SPARKLE_FEED_URL"
[[ "$(plist_value "$STAGED_INFO" SUPublicEDKey)" == "$SPARKLE_PUBLIC_ED_KEY" ]] || die "the app's SUPublicEDKey is not Veylor's"
[[ "$(plist_value "$STAGED_INFO" SURequireSignedFeed)" == "true" ]] || die "the app does not require a signed feed"
[[ "$(plist_value "$STAGED_INFO" SUVerifyUpdateBeforeExtraction)" == "true" ]] || die "the app does not verify updates before extraction"
[[ "$(plist_value "$STAGED_INFO" CFBundleVersion)" == "$BUILD_NUMBER" ]] || die "the staged app is not build $BUILD_NUMBER"
note "feed: $SPARKLE_FEED_URL"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP" >"$LOG_DIR/codesign-verify.log" 2>&1 ||
  die "the app's signature does not verify (see $LOG_DIR/codesign-verify.log)"
check_signature "$STAGED_APP"
APP_SIGNATURE="$(/usr/bin/codesign -dvv "$STAGED_APP" 2>&1)"
grep -q "flags=.*runtime" <<<"$APP_SIGNATURE" || die "the app lacks the hardened runtime"
while IFS= read -r code; do
  check_signature "$code"
done < <(nested_code "$STAGED_APP")

ENTITLEMENTS="$WORK_DIR/entitlements.plist"
/usr/bin/codesign -d --entitlements - --xml "$STAGED_APP" >"$ENTITLEMENTS" 2>/dev/null
[[ "$(plist_value "$ENTITLEMENTS" com.apple.application-identifier)" == "$VEYLOR_TEAM_ID.$BUNDLE_ID" ]] ||
  die "the app's application-identifier is not $VEYLOR_TEAM_ID.$BUNDLE_ID"
[[ "$(plist_value "$ENTITLEMENTS" com.apple.developer.team-identifier)" == "$VEYLOR_TEAM_ID" ]] ||
  die "the app's team-identifier is not $VEYLOR_TEAM_ID"
[[ "$(plist_value "$ENTITLEMENTS" com.apple.security.app-sandbox)" == "true" ]] || die "the app is not sandboxed"
if plist_value "$ENTITLEMENTS" com.apple.security.get-task-allow >/dev/null; then
  die "the app carries get-task-allow"
fi
MACH_LOOKUP="$(plist_value "$ENTITLEMENTS" com.apple.security.temporary-exception.mach-lookup.global-name || true)"
grep -q "$BUNDLE_ID-spki" <<<"$MACH_LOOKUP" || die "Sparkle's installer mach-lookup entitlement is missing"
EMBEDDED_PROFILE="$WORK_DIR/embedded-profile.plist"
security cms -D -i "$STAGED_APP/Contents/embedded.provisionprofile" >"$EMBEDDED_PROFILE" 2>/dev/null ||
  die "the app embeds no provisioning profile"
[[ "$(plist_value "$EMBEDDED_PROFILE" Name)" == "$PROFILE_NAME" ]] || die "the app embeds another profile"
note "signature, entitlements and profile check out"

# ---------------------------------------------------------------------------
log "Notarizing the app"
if [[ "$RESUME" == true ]] && xcrun stapler validate -q "$STAGED_APP" >/dev/null 2>&1; then
  note "already notarized and stapled"
  NOTARY_IDS+=("app=$(cat "$WORK_DIR/notary-app.id" 2>/dev/null || echo unknown)")
else
  APP_ZIP="$WORK_DIR/$APP_NAME-notarize.zip"
  if [[ "$RESUME" != true || ! -s "$WORK_DIR/notary-app.id" ]]; then
    rm -f "$APP_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$APP_ZIP"
  fi
  notarize "$APP_ZIP" app
  xcrun stapler staple "$STAGED_APP" >"$LOG_DIR/staple-app.log" 2>&1 || die "stapling the app failed (see $LOG_DIR/staple-app.log)"
fi
xcrun stapler validate "$STAGED_APP" >>"$LOG_DIR/staple-app.log" 2>&1 || die "the app's ticket does not validate"
spctl --assess --type execute --verbose=4 "$STAGED_APP" >"$LOG_DIR/spctl-app.log" 2>&1 ||
  die "Gatekeeper rejects the app (see $LOG_DIR/spctl-app.log)"
note "$(tr '\n' ' ' <"$LOG_DIR/spctl-app.log")"

# ---------------------------------------------------------------------------
log "Packaging $DMG_ASSET"
DMG_PATH="$WORK_DIR/$DMG_ASSET"
DMG_STAPLED=false
if [[ "$RESUME" == true && -f "$DMG_PATH" ]] && xcrun stapler validate -q "$DMG_PATH" >/dev/null 2>&1; then
  note "already packaged, notarized and stapled"
  DMG_STAPLED=true
elif [[ "$RESUME" == true && -f "$DMG_PATH" && -s "$WORK_DIR/notary-dmg.id" ]]; then
  note "keeping the stopped run's submitted DMG"
else
  rm -f "$DMG_PATH" "$WORK_DIR/notary-dmg.id"
  "$PYTHON" -I -m venv "$TOOLS_VENV" >/dev/null 2>&1 || true
  [[ -x "$TOOLS_VENV/bin/python" ]] || die "could not create the packaging virtualenv"
  "$TOOLS_VENV/bin/python" -I -m pip install --disable-pip-version-check --quiet \
    --require-hashes --only-binary=:all: --no-deps \
    -r "$ROOT_DIR/scripts/veylor-macos-release/requirements.txt" >"$LOG_DIR/pip.log" 2>&1 ||
    die "installing dmgbuild failed (see $LOG_DIR/pip.log)"
  "$TOOLS_VENV/bin/python" -I "$ROOT_DIR/scripts/veylor-macos-release/build_dmg.py" \
    --app "$STAGED_APP" \
    --output "$DMG_PATH" \
    --volume-name "$VOLUME_NAME" \
    --background "$ROOT_DIR/macos/Packaging/DMG/veylor/background.png" \
    --volume-icon "$STAGED_APP/Contents/Resources/$APP_ICON_FILE.icns"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
fi
/usr/bin/codesign --verify --verbose=2 "$DMG_PATH" >"$LOG_DIR/codesign-dmg.log" 2>&1 || die "the DMG's signature does not verify"
check_signature "$DMG_PATH"

log "Notarizing $DMG_ASSET"
if [[ "$DMG_STAPLED" == true ]]; then
  NOTARY_IDS+=("dmg=$(cat "$WORK_DIR/notary-dmg.id" 2>/dev/null || echo unknown)")
else
  notarize "$DMG_PATH" dmg
  xcrun stapler staple "$DMG_PATH" >"$LOG_DIR/staple-dmg.log" 2>&1 || die "stapling the DMG failed (see $LOG_DIR/staple-dmg.log)"
fi
xcrun stapler validate "$DMG_PATH" >>"$LOG_DIR/staple-dmg.log" 2>&1 || die "the DMG's ticket does not validate"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" >"$LOG_DIR/spctl-dmg.log" 2>&1 ||
  die "Gatekeeper rejects the DMG (see $LOG_DIR/spctl-dmg.log)"
note "$(tr '\n' ' ' <"$LOG_DIR/spctl-dmg.log")"

# ---------------------------------------------------------------------------
log "Writing the Sparkle appcast"
ARCHIVES_DIR="$WORK_DIR/appcast"
rm -rf "$ARCHIVES_DIR"
mkdir -p "$ARCHIVES_DIR"
cp "$DMG_PATH" "$ARCHIVES_DIR/$DMG_ASSET"
cp "$NOTES_PATH" "$ARCHIVES_DIR/$NOTES_ASSET"
sparkle_tool generate_appcast "${SPARKLE_KEY_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix "$DOWNLOAD_PREFIX" \
  --full-release-notes-url "$RELEASE_PAGE_URL" \
  --link "$RELEASE_PAGE_URL" \
  --versions "$BUILD_NUMBER" \
  --maximum-versions 1 \
  -o "$ARCHIVES_DIR/$APPCAST_ASSET" \
  "$ARCHIVES_DIR" >"$LOG_DIR/generate-appcast.log" 2>&1 ||
  die "generate_appcast failed (see $LOG_DIR/generate-appcast.log)"
# The app requires a signed feed: sign the finished appcast.
sparkle_tool sign_update "${SPARKLE_KEY_ARGS[@]}" "$ARCHIVES_DIR/$APPCAST_ASSET" >"$LOG_DIR/sign-appcast.log" 2>&1 ||
  die "signing the appcast failed (see $LOG_DIR/sign-appcast.log)"

SIGNATURES="$("$PYTHON" -I "$ROOT_DIR/scripts/veylor-macos-release/check_appcast.py" \
  --appcast "$ARCHIVES_DIR/$APPCAST_ASSET" \
  --dmg "$ARCHIVES_DIR/$DMG_ASSET" \
  --notes "$ARCHIVES_DIR/$NOTES_ASSET" \
  --dmg-url "$DMG_URL" \
  --notes-url "$NOTES_URL" \
  --version "$VERSION" \
  --build "$BUILD_NUMBER" \
  --minimum-system-version "$MINIMUM_SYSTEM_VERSION")" || die "the appcast does not describe this release"
DMG_SIGNATURE="$(sed -n 1p <<<"$SIGNATURES")"
NOTES_SIGNATURE="$(sed -n 2p <<<"$SIGNATURES")"
sparkle_tool sign_update "${SPARKLE_KEY_ARGS[@]}" --verify "$ARCHIVES_DIR/$APPCAST_ASSET" >/dev/null 2>&1 ||
  die "the appcast's signature does not verify"
sparkle_tool sign_update "${SPARKLE_KEY_ARGS[@]}" --verify "$ARCHIVES_DIR/$DMG_ASSET" "$DMG_SIGNATURE" >/dev/null 2>&1 ||
  die "the DMG's EdDSA signature does not verify"
sparkle_tool sign_update "${SPARKLE_KEY_ARGS[@]}" --verify "$ARCHIVES_DIR/$NOTES_ASSET" "$NOTES_SIGNATURE" >/dev/null 2>&1 ||
  die "the release notes' EdDSA signature does not verify"
cmp -s "$DMG_PATH" "$ARCHIVES_DIR/$DMG_ASSET" || die "generate_appcast changed the DMG"
note "appcast signed and checked: $DMG_URL"

# ---------------------------------------------------------------------------
log "Collecting the release assets"
cp "$ARCHIVES_DIR/$DMG_ASSET" "$OUT_DIR/$DMG_ASSET"
cp "$ARCHIVES_DIR/$APPCAST_ASSET" "$OUT_DIR/$APPCAST_ASSET"
cp "$ARCHIVES_DIR/$NOTES_ASSET" "$OUT_DIR/$NOTES_ASSET"
(cd "$OUT_DIR" && shasum -a 256 "$DMG_ASSET" "$APPCAST_ASSET" "$NOTES_ASSET" >SHA256SUMS)
cat >"$OUT_DIR/release-info.txt" <<INFO
Veylor $VERSION ($BUILD_NUMBER) for macOS, mainnet, Shielded USD on
Commit:          $BUILD_COMMIT
Tag:             $TAG
Repository:      $RELEASE_REPOSITORY
Signed by:       $SIGNING_IDENTITY
Profile:         $PROFILE_NAME
Notarization:    ${NOTARY_IDS[*]}
Minimum macOS:   $MINIMUM_SYSTEM_VERSION
Sparkle feed:    $SPARKLE_FEED_URL
Sparkle key:     $SPARKLE_PUBLIC_ED_KEY
Update archive:  $DMG_URL
Release notes:   $NOTES_URL

Upload $DMG_ASSET, $APPCAST_ASSET and $NOTES_ASSET, unchanged, to the release
tagged $TAG, and leave it a full release (not a pre-release or a draft):
the feed URL resolves through releases/latest.
INFO
rm -rf "$WORK_DIR"

CHANGED="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)"
if [[ -n "$CHANGED" ]]; then
  note "the build changed tracked files; review them:"
  printf '      %s\n' "$CHANGED"
fi

log "Done: $OUT_DIR"
(cd "$OUT_DIR" && ls -l "$DMG_ASSET" "$APPCAST_ASSET" "$NOTES_ASSET" SHA256SUMS release-info.txt)
