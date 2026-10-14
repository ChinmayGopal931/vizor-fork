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
#   --m5                 the M5 round (forward conversion) instead of M3's checks,
#                        off by default. It never resets the wallet: it converts
#                        from the testnet wallet on the phone (an earlier round's,
#                        passcode 111111), which needs testnet ZEC (E8). It runs
#                        the test's start phase, force-stops the app once the
#                        deposit is kept (killed mid-confirmation), then runs the
#                        resume phase (lock, account switch, delete warning, Paid).
#                        Implies --skip-release and keeps the page storage.
#   --m5-zec AMOUNT      ZEC to convert in the M5 round (default 0.05)
#   --m6                 the M6 round (reverse conversion), off by default. Run it
#                        after an M5 round left private USD in the same wallet
#                        (or together with --m5, after it). It never resets the
#                        wallet and keeps the page storage. It converts --m6-usd
#                        back to ZEC through the screens: a lock while the page
#                        proves the payment pays nothing; that unpaid conversion,
#                        cancelled, ends CANCELLED; a new one is paid, settlement
#                        is authorized and it reaches COMPLETE. Implies
#                        --skip-release.
#   --m6-complete-only   in the M6 round, skip the lock and cancel checks and run
#                        one conversion to COMPLETE (on Sepolia each paid try
#                        leaves its change Processing for a while)
#   --m6-fee-margin USDC private USD kept above the amount for fees (default 2.5)
#   --m6-usd AMOUNT      private USD to convert in the M6 round, whole cents
#                        (default 2)
#   --m6-refund          also: a paid conversion, cancelled, ends REFUNDED (waits
#                        out the refund deadlines; can take hours)
#   --m7                 the M7 round (private send and withdraw), off by default.
#                        Run it after an M5 round left private USD in the same
#                        wallet (or together with --m5/--m6, after them). It
#                        never resets the wallet and keeps the page storage. It
#                        runs the test's start phase (a send through the screens
#                        arrives at a second account's 0zk address and stays
#                        Processing on Sepolia; a withdrawal reaches --m7-to; a
#                        third send is kept and held before its post), force-
#                        stops the app (killed between proving and the post),
#                        then runs the resume phase (settlement posts the kept
#                        bytes; nothing is proved again). Implies --skip-release.
#   --m7-to ADDRESS      the 0x address the withdrawal pays (required with --m7)
#   --m7-usd AMOUNT      private USD per send and withdrawal (default 1)
#   --m8-route           the M8 route round, off by default: Tor turns on in the
#                        middle of a forward claim (converting --m5-zec), a
#                        reverse funding (--m6-usd, while the page proves the
#                        payment) and a private send (--m7-usd to a second
#                        account's 0zk, while the page proves it). From the flip
#                        on no host sample may show a direct socket to a Railgun
#                        host, and once Tor has connected none may show a socket
#                        that is neither loopback nor a Tor relay
#                        (check_sockets.py --onionoo); each phase must then
#                        finish over Tor. Run it after an M5 round left private
#                        USD, with testnet ZEC left for its own forward
#                        conversion (or together with --m5/--m6/--m7, after
#                        them). It never resets the wallet, keeps the page
#                        storage, and implies --skip-release.
#   --m8-route-phases L  a comma list of forward, reverse and send (default all
#                        three, in that order)
#   --keyed-rpc FILE     the keyed RPC check (M8.3). FILE is a JSON file for
#                        --dart-define-from-file that sets
#                        VIZOR_ETHEREUM_RPC_URL_SEPOLIA (the round runs on
#                        Sepolia; _MAINNET may be set too), the keyed RPC (E6).
#                        Keep it outside the repo or gitignored: the runner
#                        refuses a file git tracks or would track. Every build
#                        in the round uses it. After the test the host reads the
#                        app's Private USD files (swaps.db with its WAL, joint.db,
#                        the token state) and shared_prefs with run-as from the
#                        debug build; at the end it dumps logcat and scans every
#                        log and evidence file of the round. Any match of the
#                        URL's host and path, or of its key, fails the round.
#                        Nothing prints the URL or the key.
#
# Safety: it refuses a phone whose com.keplr.vizor is installed but not
# debuggable (that may be a real wallet), runs `flutter test --no-uninstall`,
# and never uninstalls anything. It keeps the screen on while plugged in over
# USB (U21) and restores the original setting on exit, also on failure.
set -euo pipefail

CALLER_DIR=$PWD
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
M5=0 M5_ZEC=0.05 M6=0 M6_USD=2 M6_REFUND=false M6_COMPLETE_ONLY=false M6_FEE_MARGIN=2.5 M7=0 M7_USD=1 M7_TO=""
M8_ROUTE=0 M8_PHASES=forward,reverse,send KEYED_RPC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --m5) M5=1; RUN_RELEASE=0; KEEP_PAGE=1; shift ;;
    --m5-zec) M5_ZEC=$2; shift 2 ;;
    --m6) M6=1; RUN_RELEASE=0; KEEP_PAGE=1; shift ;;
    --m6-usd) M6_USD=$2; shift 2 ;;
    --m6-refund) M6_REFUND=true; shift ;;
    --m6-complete-only) M6_COMPLETE_ONLY=true; shift ;;
    --m6-fee-margin) M6_FEE_MARGIN=$2; shift 2 ;;
    --m7) M7=1; RUN_RELEASE=0; KEEP_PAGE=1; shift ;;
    --m7-to) M7_TO=$2; shift 2 ;;
    --m7-usd) M7_USD=$2; shift 2 ;;
    --m8-route) M8_ROUTE=1; RUN_RELEASE=0; KEEP_PAGE=1; shift ;;
    --m8-route-phases) M8_PHASES=$2; shift 2 ;;
    --keyed-rpc) KEYED_RPC=$2; shift 2 ;;
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
if [[ $M7 == 1 && ! $M7_TO =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "--m7 needs --m7-to 0x… (40 hex digits): the withdrawal's address" >&2
  exit 2
fi
if [[ ! $M8_PHASES =~ ^(forward|reverse|send)(,(forward|reverse|send))*$ ]]; then
  echo "--m8-route-phases takes a comma list of forward, reverse and send" >&2
  exit 2
fi
if [[ -n $KEYED_RPC ]]; then
  [[ $KEYED_RPC == /* ]] || KEYED_RPC="$CALLER_DIR/$KEYED_RPC"
  if [[ ! -f $KEYED_RPC || ! -r $KEYED_RPC ]]; then
    echo "--keyed-rpc: no readable file at $KEYED_RPC" >&2
    exit 2
  fi
  # The key must never reach the repo.
  if git ls-files --error-unmatch -- "$KEYED_RPC" >/dev/null 2>&1; then
    echo "--keyed-rpc: git tracks $KEYED_RPC; keep the key out of the repo" >&2
    exit 2
  fi
  if [[ $KEYED_RPC == "$PWD"/* ]] && ! git check-ignore -q -- "$KEYED_RPC"; then
    echo "--keyed-rpc: $KEYED_RPC is in the repo and not gitignored" >&2
    exit 2
  fi
  # Checks the URL's shape without printing it.
  python3 -I scripts/private-usd/device_round.py keyed-rpc-check --file "$KEYED_RPC" --require sepolia || exit 2
  DEFINES+=(--dart-define-from-file="$KEYED_RPC")
fi
mkdir -p "$OUT"

log() { echo "$(date +%H:%M:%S) [round] $*" | tee -a "$OUT/round.log"; }
adb_() { "$ADB" -s "$SERIAL" "$@"; }

PIDS=()
ORIG_STAY_ON=""
TEST_STATUS=0 RELEASE_STATUS=0 RESTORE_STATUS=0 KEYED_FILES_STATUS=0 KEYED_LOGS_STATUS=0

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
  set +e
  if [[ $M5 == 1 ]]; then
    # Never VIZOR_PUSD_DEVICE_RESET: the round converts the phone's funded
    # wallet, and the test refuses to run with it.
    m5_test() {
      fvm flutter test integration_test/private_usd_device_test.dart \
        -d "$SERIAL" --tags private-usd-device --run-skipped --no-uninstall \
        "${DEFINES[@]}" \
        --dart-define=ZCASH_E2E_NETWORK=testnet \
        --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="http://127.0.0.1:$PORT" \
        --dart-define=VIZOR_PUSD_DEVICE_M5="$1" \
        --dart-define=VIZOR_PUSD_DEVICE_M5_ZEC="$M5_ZEC" \
        2>&1 | tee "$OUT/flutter-test-m5-$1.log"
      return "${PIPESTATUS[0]}"
    }
    log "M5 round, start phase: convert $M5_ZEC ZEC until the deposit is kept"
    m5_test start
    TEST_STATUS=$?
    if [[ $TEST_STATUS == 0 ]]; then
      adb_ shell am force-stop "$PACKAGE"
      log "killed the app mid-confirmation (am force-stop)"
      sleep 5
      ensure_screen_ready
      log "M5 round, resume phase: kill, lock, account switch, delete warning, Paid"
      m5_test resume
      TEST_STATUS=$?
    fi
  fi
  if [[ $M6 == 1 && $TEST_STATUS == 0 ]]; then
    # Never VIZOR_PUSD_DEVICE_RESET: the round converts the private USD an
    # M5 round left in the phone's wallet.
    log "M6 round: convert $M6_USD private USD to ZEC (refund check: $M6_REFUND)"
    fvm flutter test integration_test/private_usd_device_test.dart \
      -d "$SERIAL" --tags private-usd-device --run-skipped --no-uninstall \
      "${DEFINES[@]}" \
      --dart-define=ZCASH_E2E_NETWORK=testnet \
      --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="http://127.0.0.1:$PORT" \
      --dart-define=VIZOR_PUSD_DEVICE_M6=run \
      --dart-define=VIZOR_PUSD_DEVICE_M6_USD="$M6_USD" \
      --dart-define=VIZOR_PUSD_DEVICE_M6_REFUND=$M6_REFUND \
      --dart-define=VIZOR_PUSD_DEVICE_M6_COMPLETE_ONLY=$M6_COMPLETE_ONLY \
      --dart-define=VIZOR_PUSD_DEVICE_M6_FEE_MARGIN="$M6_FEE_MARGIN" \
      2>&1 | tee "$OUT/flutter-test-m6.log"
    TEST_STATUS=${PIPESTATUS[0]}
  fi
  if [[ $M7 == 1 && $TEST_STATUS == 0 ]]; then
    # Never VIZOR_PUSD_DEVICE_RESET: the round sends the private USD an M5
    # round left in the phone's wallet.
    m7_test() {
      fvm flutter test integration_test/private_usd_device_test.dart \
        -d "$SERIAL" --tags private-usd-device --run-skipped --no-uninstall \
        "${DEFINES[@]}" \
        --dart-define=ZCASH_E2E_NETWORK=testnet \
        --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="http://127.0.0.1:$PORT" \
        --dart-define=VIZOR_PUSD_DEVICE_M7="$1" \
        --dart-define=VIZOR_PUSD_DEVICE_M7_USD="$M7_USD" \
        --dart-define=VIZOR_PUSD_DEVICE_M7_TO="$M7_TO" \
        2>&1 | tee "$OUT/flutter-test-m7-$1.log"
      return "${PIPESTATUS[0]}"
    }
    log "M7 round, start phase: send, withdraw, then a send held before its post"
    m7_test start
    TEST_STATUS=$?
    if [[ $TEST_STATUS == 0 ]]; then
      adb_ shell am force-stop "$PACKAGE"
      log "killed the app between proving and the post (am force-stop)"
      sleep 5
      ensure_screen_ready
      log "M7 round, resume phase: settlement posts the kept send, nothing is proved"
      m7_test resume
      TEST_STATUS=$?
    fi
  fi
  if [[ $M8_ROUTE == 1 && $TEST_STATUS == 0 ]]; then
    # Never VIZOR_PUSD_DEVICE_RESET: the round converts and sends what the
    # earlier rounds left in the phone's wallet.
    log "M8 route round: Tor turns on mid-phase ($M8_PHASES)"
    fvm flutter test integration_test/private_usd_device_test.dart \
      -d "$SERIAL" --tags private-usd-device --run-skipped --no-uninstall \
      "${DEFINES[@]}" \
      --dart-define=ZCASH_E2E_NETWORK=testnet \
      --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="http://127.0.0.1:$PORT" \
      --dart-define=VIZOR_PUSD_DEVICE_M8_ROUTE="$M8_PHASES" \
      --dart-define=VIZOR_PUSD_DEVICE_M5_ZEC="$M5_ZEC" \
      --dart-define=VIZOR_PUSD_DEVICE_M6_USD="$M6_USD" \
      --dart-define=VIZOR_PUSD_DEVICE_M7_USD="$M7_USD" \
      2>&1 | tee "$OUT/flutter-test-m8-route.log"
    TEST_STATUS=${PIPESTATUS[0]}
  fi
  if [[ $M5 == 0 && $M6 == 0 && $M7 == 0 && $M8_ROUTE == 0 ]]; then
    log "running the integration test (fresh page storage: $fresh, Tor first sync: $TOR_FIRST_SYNC)"
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
  fi
  set -e
  stop_pid "$SAMPLER_PID"
  stop_pid "$LOGCAT_PID"
  log "integration test exit status: $TEST_STATUS"
fi

# ── The keyed RPC in the app's files (M8.3) ───────────────────────────

if [[ -n $KEYED_RPC ]]; then
  # run-as needs the debug build the test left; stop the app so its
  # databases are not mid-write.
  adb_ shell am force-stop "$PACKAGE" || true
  set +e
  python3 -I scripts/private-usd/device_round.py keyed-rpc-scan --file "$KEYED_RPC" --out "$OUT" --app-files
  KEYED_FILES_STATUS=$?
  set -e
  log "keyed RPC check, app files: status $KEYED_FILES_STATUS"
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

# ── The keyed RPC in logcat and the round's logs (M8.3) ───────────────

if [[ -n $KEYED_RPC ]]; then
  adb_ logcat -d -v threadtime >"$OUT/logcat-final.txt" 2>&1 || true
  set +e
  python3 -I scripts/private-usd/device_round.py keyed-rpc-scan --file "$KEYED_RPC" --out "$OUT" --logs
  KEYED_LOGS_STATUS=$?
  set -e
  log "keyed RPC check, logs: status $KEYED_LOGS_STATUS"
fi

python3 -I scripts/private-usd/device_round.py summarize --out "$OUT" >"$OUT/summary.json" 2>&1 || true
log "evidence: $OUT"
if [[ $TEST_STATUS != 0 || $RELEASE_STATUS != 0 || $RESTORE_STATUS != 0 \
  || $KEYED_FILES_STATUS != 0 || $KEYED_LOGS_STATUS != 0 ]]; then
  exit 1
fi
