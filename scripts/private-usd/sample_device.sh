#!/usr/bin/env bash
# Samples an app's memory, and its WebView renderer's, every 10 s; and every
# 30 s checks the app's sockets (check_sockets.py --onionoo). Used in Private
# USD device rounds. Stop it with Ctrl-C, or pass a duration.
#
# Usage: ANDROID_SERIAL=<serial> scripts/private-usd/sample_device.sh <out prefix> [seconds] [package]
# Writes <out prefix>-mem.txt and <out prefix>-sockets.txt.
set -euo pipefail

OUT=${1:?usage: sample_device.sh <out prefix> [seconds] [package]}
DURATION=${2:-0}
PACKAGE=${3:-com.keplr.vizor}
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

app_id=$("$ADB" shell dumpsys package "$PACKAGE" | sed -nE 's/.*(appId|userId)=([0-9]+).*/\2/p' | head -1)
[ -n "$app_id" ] || { echo "$PACKAGE is not installed" >&2; exit 1; }
# Isolated renderer processes carry their host app as u0a<appId - 10000>i…
host_tag="u0a$((app_id - 10000))i"

start=$(date +%s); n=0
while [ "$DURATION" -eq 0 ] || [ $(( $(date +%s) - start )) -lt "$DURATION" ]; do
  app=$("$ADB" shell dumpsys meminfo "$PACKAGE" 2>/dev/null | awk '/TOTAL PSS/ {print $3}')
  rpid=$("$ADB" shell dumpsys activity processes 2>/dev/null \
    | grep -E "ProcessRecord\{[0-9a-f]+ [0-9]+:com\.google\.android\.webview:sandboxed_process0.*/${host_tag}" \
    | sed -E 's/.*ProcessRecord\{[0-9a-f]+ ([0-9]+):.*/\1/' | head -1 || true)
  rend=""
  [ -n "$rpid" ] && rend=$("$ADB" shell dumpsys meminfo "$rpid" 2>/dev/null | awk '/TOTAL PSS/ {print $3}')
  echo "$(date +%H:%M:%S) app_pss_kb=${app} renderer_pid=${rpid} renderer_pss_kb=${rend}" >> "$OUT-mem.txt"
  if (( n % 3 == 0 )); then
    { echo "== $(date +%H:%M:%S)"; python3 -I "$HERE/check_sockets.py" --onionoo "$PACKAGE" || true; } >> "$OUT-sockets.txt" 2>&1
  fi
  n=$((n + 1)); sleep 10
done
