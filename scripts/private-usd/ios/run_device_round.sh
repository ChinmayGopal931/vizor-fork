#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/private-usd/ios/run_device_round.sh (--simulator UDID | --device UDID) [options]

The Private USD device round on iOS, against Zcash testnet and Ethereum
Sepolia, on a booted simulator or an iPhone with iOS 17 or later. The order
of rounds is in docs/private-usd-ios-device-checklist.md.

  1. integration_test/private_usd_device_test.dart's first round (the strip
     before first use, the first sync and the address, Tor on and off, the
     lock, the unlock), with the host checkpoints it calls
     (device_round_ios.py serve). The simulator shares this Mac's loopback,
     and its app is a process of this Mac: the driver samples its listeners,
     its sockets and WebKit's (lsof), its WebContent processes and memory. An
     iPhone reaches the driver over the local network, under a random token;
     there the test checks the page and its bridge from the app, and rvictl
     and tcpdump (sudo) capture the iPhone's traffic.
  2. On an iPhone, the capture verdict: while Tor was on, no connection to a
     Railgun host and no DNS query for one (device_round_ios.py
     capture-verdict, classified like check_sockets.py --onionoo).

Options:
  --out DIR            evidence directory
                       (default: $TMPDIR/pusd-ios-round-<time>)
  --bundle-id ID       the installed app's bundle ID (default com.keplr.vizor).
                       On a personal iPhone, build with a side-by-side bundle
                       ID (never committed) and pass it here.
  --host-ip ADDR       (iPhone) the Mac's address on the iPhone's network
                       (default: en0's)
  --keep-page-data     keep the Railgun page's data store (no true first sync)
  --no-tor-first-sync  skip the first sync through Tor
  --skip-test          only the capture verdict of an earlier --out (iPhone)
  -h, --help           show this help

Relative paths are taken from the directory the runner was started in.

The Android runner's other rounds (--m5, --m6, --m7, --deposits, --m8-route,
--keyed-rpc) are not here yet: they kill the app between two `flutter test`
runs, and whether `flutter test` keeps the app's data between runs on iOS is
not settled.

Safety: it never boots a simulator (boot one first) and never uninstalls
(flutter test --no-uninstall). It refuses an iPhone whose installed app is
not a development build: a development build signed with the App Store bundle
ID would replace an App Store Veylor and inherit its wallet. It also refuses
when it can't tell. The round resets this build's testnet wallet only.

Not automated here: the screen (set Auto-Lock to Never for an iPhone round
and restore it after; iOS has no `svc power stayon`), the release-build check
(a release build runs only on an iPhone signed with the owner's team: by
hand, from the iOS device checklist), and memory on an iPhone (Xcode or
xctrace).

Unverified until the first device session: the driver's simulator labels for
WebKit, devicectl's app field `builtByDeveloper`, tcpdump on rvi0, and the
Local Network prompt an iPhone shows the first time the test reaches the
driver (accept it).
EOF
}

CALLER_DIR=$PWD
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
DRIVER=scripts/private-usd/ios/device_round_ios.py
PORT=${PUSD_DRIVER_PORT:-39168}
BUNDLE_ID=com.keplr.vizor
DEFINES=(
  --dart-define=VIZOR_FORM_FACTOR=mobile
  --dart-define=VIZOR_PRIVATE_USD_ENABLED=true
  --dart-define=ZCASH_DEFAULT_NETWORK=test
)
# Cargokit builds the debug Rust library with full debuginfo otherwise; the disk here runs near-full.
export CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG:-0}
export CARGO_INCREMENTAL=${CARGO_INCREMENTAL:-0}

OUT="${TMPDIR:-/tmp}/pusd-ios-round-$(date +%Y%m%d-%H%M%S)"
TARGET="" UDID="" HOST_IP="" RUN_TEST=1 KEEP_PAGE=0 TOR_FIRST_SYNC=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator) TARGET=sim; UDID="${2:-}"; shift 2 ;;
    --device) TARGET=device; UDID="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --host-ip) HOST_IP="${2:-}"; shift 2 ;;
    --keep-page-data) KEEP_PAGE=1; shift ;;
    --no-tor-first-sync) TOR_FIRST_SYNC=false; shift ;;
    --skip-test) RUN_TEST=0; shift ;;
    --m5|--m6|--m7|--deposits|--m8-route|--keyed-rpc)
      echo "$1: the iOS runner has only the first round so far" >&2
      exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n $TARGET && -n $UDID ]] || { echo "pass --simulator UDID or --device UDID" >&2; exit 2; }
[[ $OUT == /* ]] || OUT="$CALLER_DIR/$OUT"
mkdir -p "$OUT"

log() { echo "$(date +%H:%M:%S) [round] $*" | tee -a "$OUT/round.log"; }

PIDS=()
TCPDUMP_PID="" RVICTL=0
TEST_STATUS=0 CAPTURE_STATUS=0

stop_capture() {
  if [[ -n $TCPDUMP_PID ]]; then
    sudo kill -INT "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    TCPDUMP_PID=""
  fi
  if [[ $RVICTL == 1 ]]; then
    rvictl -x "$UDID" >/dev/null 2>&1 || true
    RVICTL=0
    log "removed the iPhone's capture interface"
  fi
}

cleanup() {
  local status=$?
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  stop_capture
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ── Preflight ──────────────────────────────────────────────────────────

{
  echo "git: $(git rev-parse --short HEAD) $(git status --porcelain | wc -l | tr -d ' ') changed file(s)"
  echo "target: $TARGET $UDID, bundle id $BUNDLE_ID"
} | tee "$OUT/device.txt"

if [[ $TARGET == sim ]]; then
  if ! xcrun simctl list devices booted | grep -q "($UDID) (Booted)"; then
    log "simulator $UDID is not booted: boot it first (this runner never boots one)"
    exit 3
  fi
  xcrun simctl list devices booted | grep "($UDID)" | sed 's/^ *//' >>"$OUT/device.txt"
  BIND=127.0.0.1
  DRIVER_URL="http://127.0.0.1:$PORT"
  TOKEN=""
else
  if ! xcrun devicectl list devices 2>/dev/null | grep -q "$UDID"; then
    log "no paired iPhone $UDID (xcrun devicectl list devices)"
    exit 3
  fi
  set +e
  python3 -I "$DRIVER" app-check --device "$UDID" --bundle-id "$BUNDLE_ID" | tee -a "$OUT/round.log"
  APP_STATE=${PIPESTATUS[0]}
  set -e
  if [[ $APP_STATE != 0 ]]; then
    log "REFUSING: the installed $BUNDLE_ID may be a real wallet, or the runner can't tell. Nothing was changed."
    exit 4
  fi
  HOST_IP=${HOST_IP:-$(ipconfig getifaddr en0 || true)}
  [[ -n $HOST_IP ]] || { log "no address for this Mac on the iPhone's network: pass --host-ip"; exit 3; }
  BIND=$HOST_IP
  TOKEN=$(python3 -I "$DRIVER" token)
  DRIVER_URL="http://$HOST_IP:$PORT/t/$TOKEN"
  log "Auto-Lock: set it to Never on the iPhone for the round, and restore it after"
fi

# ── 1. The integration test ────────────────────────────────────────────

if [[ $RUN_TEST == 1 ]]; then
  python3 -I "$DRIVER" serve --port "$PORT" --out "$OUT" --target "$TARGET:$UDID" --bind "$BIND" \
    --token "$TOKEN" --bundle-id "$BUNDLE_ID" >"$OUT/driver.log" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    curl -fsS "${DRIVER_URL}/health" >/dev/null 2>&1 && break
    sleep 0.2
  done
  curl -fsS "${DRIVER_URL}/health" >/dev/null || { log "the driver did not start (driver.log)"; exit 3; }

  if [[ $TARGET == device ]]; then
    log "capturing the iPhone's traffic (rvictl and tcpdump need your password for sudo)"
    sudo -v
    rvictl -s "$UDID" | tee -a "$OUT/round.log"
    RVICTL=1
    # Only tcpdump runs as root: it writes the capture; its own log stays the user's.
    # shellcheck disable=SC2024
    sudo tcpdump -i rvi0 -n -U -w "$OUT/capture.pcap" >"$OUT/tcpdump.log" 2>&1 &
    TCPDUMP_PID=$!
  fi

  fresh=true
  [[ $KEEP_PAGE == 1 ]] && fresh=false
  # The driver's token stays out of the logs.
  REDACT=""
  [[ -n $TOKEN ]] && REDACT="s/$TOKEN/<token>/g"
  log "running the integration test (fresh page data: $fresh, Tor first sync: $TOR_FIRST_SYNC)"
  set +e
  fvm flutter test integration_test/private_usd_device_test.dart \
    -d "$UDID" --tags private-usd-device --run-skipped --no-uninstall \
    "${DEFINES[@]}" \
    --dart-define=ZCASH_E2E_NETWORK=testnet \
    --dart-define=VIZOR_PUSD_DEVICE_DRIVER_URL="$DRIVER_URL" \
    --dart-define=VIZOR_PUSD_DEVICE_RESET=true \
    --dart-define=VIZOR_PUSD_DEVICE_FRESH_PAGE=$fresh \
    --dart-define=VIZOR_PUSD_DEVICE_TOR_FIRST_SYNC=$TOR_FIRST_SYNC \
    2>&1 | sed -e "$REDACT" | tee "$OUT/flutter-test.log"
  TEST_STATUS=${PIPESTATUS[0]}
  set -e
  log "integration test exit status: $TEST_STATUS"
  stop_capture
fi

# ── 2. The capture verdict (iPhone) ────────────────────────────────────

if [[ $TARGET == device ]]; then
  if [[ -f $OUT/capture.pcap ]]; then
    set +e
    python3 -I "$DRIVER" capture-verdict --pcap "$OUT/capture.pcap" --out "$OUT" --onionoo | tee -a "$OUT/round.log"
    CAPTURE_STATUS=${PIPESTATUS[0]}
    set -e
    log "capture verdict: status $CAPTURE_STATUS"
  else
    log "no capture to judge"
    CAPTURE_STATUS=2
  fi
fi

python3 -I "$DRIVER" summarize --out "$OUT" >"$OUT/summary.json" 2>&1 || true
log "evidence: $OUT"
if [[ $TEST_STATUS != 0 || $CAPTURE_STATUS != 0 ]]; then
  exit 1
fi
