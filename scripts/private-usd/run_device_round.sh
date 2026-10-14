#!/usr/bin/env bash
# The Private USD device round (docs/private-usd-android-plan.md §10) on a
# physical Android phone, against Zcash testnet and Ethereum Sepolia:
#
#   1. integration_test/private_usd_device_test.dart, with the host checkpoints
#      it calls (device_round.py serve, over adb reverse) and sample_device.sh
#      sampling memory and sockets in parallel;
#   2. the R8 release build installed over it (release signing falls back to
#      the debug key here, so the test's wallet survives), driven from the host
#      with adb input and uiautomator until /private-usd has refreshed
#      (device_round.py release-check);
#   3. a debug build of lib/main.dart installed again, so the next round's
#      debuggable check passes.
#
# Usage: ANDROID_SERIAL=<serial> scripts/private-usd/run_device_round.sh [options]
#   --out DIR            evidence directory (default: $TMPDIR/pusd-device-round-<time>)
#   --release-apk PATH   use this arm64 release APK (same defines) instead of building
#   --skip-test | --skip-release | --skip-restore
#   --keep-page-data     keep the Railgun page storage (no true first sync)
#   --no-tor-first-sync  skip the first sync through Tor
#
# Safety: it refuses a phone whose com.keplr.vizor is installed but not
# debuggable (that may be a real wallet), runs `flutter test --no-uninstall`,
# and never uninstalls anything. It keeps the screen on while plugged in over
# USB (U21) and restores the original setting on exit, also on failure.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SERIAL=${ANDROID_SERIAL:?set ANDROID_SERIAL to the phone adb serial}
export ANDROID_SERIAL=$SERIAL
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PACKAGE=com.keplr.vizor
PORT=${PUSD_DRIVER_PORT:-39168}
# The throwaway test wallet's passcode (mobileE2ePasscode).
PASSCODE=111111
DEFINES=(
  --dart-define=VIZOR_FORM_FACTOR=mobile
  --dart-define=VIZOR_PRIVATE_USD_ENABLED=true
  --dart-define=ZCASH_DEFAULT_NETWORK=test
)
# Cargokit builds the debug Rust library with the dev profile (opt-level 3)
# and full debuginfo: about 6 GB for arm64 alone. The disk here runs
# near-full, so the round builds without it, as `cargo test` does locally.
export CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG:-0}
# `flutter test` always builds debug, and cargokit adds the x86 and x86_64
# emulator ABIs to every debug build (several GB more); the phone needs arm64.
export CARGOKIT_SKIP_EMULATOR_ABIS=true

OUT="${TMPDIR:-/tmp}/pusd-device-round-$(date +%Y%m%d-%H%M%S)"
RELEASE_APK=""
RUN_TEST=1 RUN_RELEASE=1 RUN_RESTORE=1 KEEP_PAGE=0 TOR_FIRST_SYNC=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --release-apk) RELEASE_APK=$2; shift 2 ;;
    --skip-test) RUN_TEST=0; shift ;;
    --skip-release) RUN_RELEASE=0; shift ;;
    --skip-restore) RUN_RESTORE=0; shift ;;
    --keep-page-data) KEEP_PAGE=1; shift ;;
    --no-tor-first-sync) TOR_FIRST_SYNC=false; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"

log() { echo "$(date +%H:%M:%S) [round] $*" | tee -a "$OUT/round.log"; }
adb_() { "$ADB" -s "$SERIAL" "$@"; }

PIDS=()
ORIG_STAY_ON=""
TEST_STATUS=0 RELEASE_STATUS=0 RESTORE_STATUS=0

restore_stay_on() {
  [[ -n "$ORIG_STAY_ON" ]] || return 0
  if [[ "$ORIG_STAY_ON" == "null" ]]; then
    adb_ shell settings delete global stay_on_while_plugged_in >/dev/null 2>&1 || true
  else
    adb_ shell settings put global stay_on_while_plugged_in "$ORIG_STAY_ON" >/dev/null 2>&1 || true
  fi
  local now
  now=$(adb_ shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r' || true)
  if [[ "$now" == "$ORIG_STAY_ON" ]]; then
    log "restored stay_on_while_plugged_in=$now"
  else
    log "WARNING: stay_on_while_plugged_in is '$now', not the original '$ORIG_STAY_ON': restore it by hand"
  fi
  ORIG_STAY_ON=""
}

cleanup() {
  local status=$?
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  adb_ reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true
  restore_stay_on
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

stop_pid() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# absent | debuggable | other
package_state() {
  if ! adb_ shell pm list packages "$PACKAGE" | tr -d '\r' | grep -qx "package:$PACKAGE"; then
    echo absent
  elif adb_ shell dumpsys package "$PACKAGE" | grep -E '^\s*flags=' | grep -q DEBUGGABLE; then
    echo debuggable
  else
    echo other
  fi
}

keyguard_showing() {
  { adb_ shell dumpsys window; adb_ shell dumpsys activity activities; } 2>/dev/null | tr -d '\r' \
    | grep -qiE 'keyguardshowing=true|mdreaminglockscreen=true|showinglockscreen=true'
}

ensure_screen_ready() {
  adb_ shell input keyevent KEYCODE_WAKEUP
  local i
  for i in $(seq 1 24); do
    keyguard_showing || return 0
    (( i == 1 )) && log "the phone shows its lock screen: unlock it (waiting up to 2 minutes)"
    sleep 5
  done
  log "the phone is still on its lock screen"
  return 1
}

start_sampler() {
  scripts/private-usd/sample_device.sh "$OUT/$1" 0 "$PACKAGE" >"$OUT/$1-sampler.log" 2>&1 &
  SAMPLER_PID=$!
  PIDS+=("$SAMPLER_PID")
}

start_logcat() {
  adb_ logcat -c >/dev/null 2>&1 || true
  adb_ logcat -v threadtime >"$OUT/$1" 2>&1 &
  LOGCAT_PID=$!
  PIDS+=("$LOGCAT_PID")
}

# ── Preflight ──────────────────────────────────────────────────────────

adb_ get-state >/dev/null 2>&1 || { log "no adb device $SERIAL"; exit 3; }
{
  echo "model: $(adb_ shell getprop ro.product.model | tr -d '\r')"
  echo "android: $(adb_ shell getprop ro.build.version.release | tr -d '\r') (sdk $(adb_ shell getprop ro.build.version.sdk | tr -d '\r'))"
  echo "webview: $(adb_ shell dumpsys package com.google.android.webview | grep -m1 versionName | tr -d '\r ')"
  echo "git: $(git rev-parse --short HEAD) $(git status --porcelain | wc -l | tr -d ' ') changed file(s)"
} | tee "$OUT/device.txt"

STATE=$(package_state)
adb_ shell dumpsys package "$PACKAGE" | grep -E 'versionName|^\s*flags=' | tr -d '\r' >"$OUT/package-before.txt" || true
log "installed $PACKAGE: $STATE"
if [[ "$STATE" == other ]]; then
  log "REFUSING: $PACKAGE is installed but not debuggable; it may be a real wallet. Nothing was changed."
  exit 4
fi

ORIG_STAY_ON=$(adb_ shell settings get global stay_on_while_plugged_in | tr -d '\r')
echo "$ORIG_STAY_ON" >"$OUT/stay-on-original.txt"
adb_ shell svc power stayon usb
log "stay_on_while_plugged_in was '$ORIG_STAY_ON'; now $(adb_ shell settings get global stay_on_while_plugged_in | tr -d '\r') (usb)"
ensure_screen_ready

# ── 1. The integration test ────────────────────────────────────────────

if [[ $RUN_TEST == 1 ]]; then
  if [[ $KEEP_PAGE == 0 && "$STATE" == debuggable ]]; then
    adb_ shell am force-stop "$PACKAGE"
    adb_ shell run-as "$PACKAGE" rm -rf app_webview
    log "wiped the Railgun page storage (app_webview) for a true first sync"
  fi
  python3 -I scripts/private-usd/device_round.py serve --port "$PORT" --out "$OUT" >"$OUT/driver.log" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.2
  done
  adb_ reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
  start_sampler sample
  start_logcat logcat-test.txt
  fresh=true
  [[ $KEEP_PAGE == 1 ]] && fresh=false
  log "running the integration test (fresh page storage: $fresh, Tor first sync: $TOR_FIRST_SYNC)"
  set +e
  fvm flutter test integration_test/private_usd_device_test.dart \
    -d "$SERIAL" --tags private-usd-device --run-skipped --no-uninstall \
    "${DEFINES[@]}" \
    --dart-define=ZCASH_E2E_NETWORK=testnet \
    --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="http://127.0.0.1:$PORT" \
    --dart-define=VIZOR_PUSD_DEVICE_RESET=true \
    --dart-define=VIZOR_PUSD_DEVICE_FRESH_PAGE=$fresh \
    --dart-define=VIZOR_PUSD_DEVICE_TOR_FIRST_SYNC=$TOR_FIRST_SYNC \
    2>&1 | tee "$OUT/flutter-test.log"
  TEST_STATUS=${PIPESTATUS[0]}
  set -e
  stop_pid "$SAMPLER_PID"
  stop_pid "$LOGCAT_PID"
  log "integration test exit status: $TEST_STATUS"
fi

# ── 2. The R8 release build loads the page ─────────────────────────────

if [[ $RUN_RELEASE == 1 ]]; then
  if [[ -z "$RELEASE_APK" ]]; then
    log "building the arm64 release APK"
    fvm flutter build apk --release --target-platform android-arm64 "${DEFINES[@]}" >"$OUT/release-build.log" 2>&1
    RELEASE_APK=build/app/outputs/flutter-apk/app-release.apk
  fi
  log "installing $RELEASE_APK over the current install (adb install -r; never uninstalls)"
  install_out=$(adb_ install -r "$RELEASE_APK" 2>&1 | tr -d '\r')
  echo "$install_out" >>"$OUT/round.log"
  if ! grep -q '^Success' <<<"$install_out"; then
    log "the release install failed; nothing was uninstalled"
    RELEASE_STATUS=1
  else
    ensure_screen_ready
    start_sampler release-sample
    set +e
    python3 -I scripts/private-usd/device_round.py release-check --out "$OUT" --passcode "$PASSCODE"
    RELEASE_STATUS=$?
    set -e
    stop_pid "$SAMPLER_PID"
  fi
  log "release check exit status: $RELEASE_STATUS"
fi

# ── 3. Leave a debuggable build behind ─────────────────────────────────

if [[ $RUN_RESTORE == 1 ]]; then
  log "building and installing a debug build of lib/main.dart"
  set +e
  fvm flutter build apk --debug --target-platform android-arm64 "${DEFINES[@]}" >"$OUT/debug-build.log" 2>&1 \
    && adb_ install -r build/app/outputs/flutter-apk/app-debug.apk >>"$OUT/round.log" 2>&1
  RESTORE_STATUS=$?
  set -e
  log "installed $PACKAGE now: $(package_state) (restore status $RESTORE_STATUS)"
fi

python3 -I scripts/private-usd/device_round.py summarize --out "$OUT" >"$OUT/summary.json" 2>&1 || true
log "evidence: $OUT"
if [[ $TEST_STATUS != 0 || $RELEASE_STATUS != 0 || $RESTORE_STATUS != 0 ]]; then
  exit 1
fi
