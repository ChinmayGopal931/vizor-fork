#!/usr/bin/env python3
"""Host side of the Private USD device rounds (docs/private-usd-android-plan.md §10).

`scripts/private-usd/run_device_round.sh` drives it; every adb call goes to
$ANDROID_SERIAL. Run it with `python3 -I`.

  serve --port P --out DIR      Checkpoint driver for
                                integration_test/private_usd_device_test.dart,
                                reached from the phone through `adb reverse`.
  release-check --out DIR       Drives an installed build with `adb shell input`
                                and `uiautomator dump`: unlock, home, the
                                Private USD strip, `/private-usd`, until the
                                page has refreshed the balance. For the R8
                                release build, which has no test harness.
  probe [--onionoo]             One sample of what `serve` checks, printed.
  summarize --out DIR           Digest of a round's evidence.
  keyed-rpc-check --file F [--require sepolia|mainnet]
                                Checks a --dart-define-from-file JSON with the
                                keyed Ethereum RPC URLs (E6): https, on a host
                                the app accepts, with a key in its path or
                                query. Prints the hosts only.
  keyed-rpc-scan --file F --out DIR (--app-files | --logs)
                                The M8.3 check: `--app-files` reads the app's
                                Private USD files (swaps.db with its WAL,
                                joint.db, the token state) and shared_prefs
                                with `run-as` (debug builds only) into memory;
                                `--logs` reads every file in DIR (logcat,
                                test and build logs, evidence). It looks for
                                each keyed URL's host and path, and for its
                                key, and writes keyed-rpc-scan-*.json. Exit 0
                                clean, 1 found, 2 could not check. It never
                                prints or writes the URL or the key, only
                                labels such as "sepolia key".

The M5, M6, M7 and M8 route rounds (`run_device_round.sh --m5`, `--m6`,
`--m7`, `--m8-route`) use the same `serve` endpoints: their events (`m5-*`,
`m6-*`, `m7-*`, `m8-*`: the swap
index, phases, outcomes and timings, never txids, addresses or secrets) and
screenshots land in the same evidence directory, and `summarize` lists them
with the rest. The M7 round also asks `serve` for a public ERC-20 balance
(`/erc20-balance`, over the deployment's keyless RPC) to see its withdrawal
arrive.

A checkpoint reports, for the app UID: whether a WebView renderer runs for
the app (the isolated `…:sandboxed_process…` process tagged with the app's
`u0a…i`), the app UID's LISTEN rows in /proc/net/tcp{,6}, memory (PSS), and
`check_sockets.py --onionoo`'s classification. Nothing here reads or prints
wallet secrets; the test never sends any.
"""
import argparse
import ast
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = "com.keplr.vizor"
ACTIVITY = f"{PACKAGE}/.MainActivity"
ADB = os.path.join(os.environ.get("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk")), "platform-tools", "adb")
UI_DUMP = "/data/local/tmp/pusd_ui.xml"
CRASH_PATTERNS = [
    "FATAL EXCEPTION",
    "ClassNotFoundException",
    "NoClassDefFoundError",
    "NoSuchMethodError",
    "NoSuchFieldError",
    "AbstractMethodError",
    "Module with the Main dispatcher is missing",
    "has died",
    "ANR in com.keplr.vizor",
]
MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


def adb(*args, binary=False, timeout=120):
    """Runs adb; a failed call raises, so a probe never passes on no data."""
    result = subprocess.run([ADB, *args], capture_output=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)[:80]} failed ({result.returncode}): {result.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return result.stdout if binary else result.stdout.decode("utf-8", "replace")


def shell(command, timeout=120):
    return adb("shell", command, timeout=timeout)


# ── Probes ───────────────────────────────────────────────────────────────


def app_id(package=PACKAGE):
    found = re.search(r"(?:userId|appId)=(\d+)", shell(f"dumpsys package {package}"))
    if not found:
        raise RuntimeError(f"{package} is not installed")
    return int(found.group(1))


def renderers(package=PACKAGE):
    """WebView renderer processes: every sandboxed one, and the app's."""
    uid = app_id(package)
    tag = f"u0a{uid - 10000}i"
    processes = shell("dumpsys activity processes")
    if "ProcessRecord{" not in processes:
        raise RuntimeError("dumpsys activity processes listed no process")
    seen = {}
    for match in re.finditer(r"ProcessRecord\{[0-9a-f]+ (\d+):(\S*?sandboxed_process\S*?)/(\S+?)\}", processes):
        seen[int(match.group(1))] = {"pid": int(match.group(1)), "name": match.group(2), "tag": match.group(3)}
    every = sorted(seen.values(), key=lambda r: r["pid"])
    mine = [r for r in every if r["tag"].startswith(tag)]
    return {"running": bool(mine), "pids": [r["pid"] for r in mine], "host_tag": tag, "all": every}


def decode(hex_addr):
    import ipaddress

    addr, port = hex_addr.split(":")
    raw = bytes.fromhex(addr)
    if len(raw) == 4:
        ip = ipaddress.IPv4Address(raw[::-1])
    else:
        words = [raw[i:i + 4][::-1] for i in range(0, 16, 4)]
        ip = ipaddress.IPv6Address(b"".join(words))
        if ip.ipv4_mapped:
            ip = ip.ipv4_mapped
    return ip, int(port, 16)


def listeners(package=PACKAGE, vm_service_port=None):
    """The app UID's LISTEN (state 0A) rows. The Dart VM service of a debug
    build listens on loopback too; it is labelled, not counted."""
    uid = app_id(package)
    rows = []
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        lines = shell(f"cat {table}").splitlines()
        if not lines or "local_address" not in lines[0]:
            raise RuntimeError(f"unreadable {table}")
        for line in lines[1:]:
            cols = line.split()
            if len(cols) < 8 or cols[7] != str(uid) or cols[3] != "0A":
                continue
            ip, port = decode(cols[1])
            label = "vm-service" if vm_service_port and port == vm_service_port else "other"
            rows.append({"table": table.rsplit("/", 1)[1], "ip": str(ip), "port": port, "loopback": ip.is_loopback, "label": label})
    other = [r for r in rows if r["label"] == "other"]
    return {"rows": rows, "other_ports": sorted({r["port"] for r in other}), "count": len(rows)}


def pss_kb(target):
    out = shell(f"dumpsys meminfo {target}")
    found = re.search(r"TOTAL PSS:\s+(\d+)", out) or re.search(r"^\s*TOTAL\s+(\d+)", out, re.M)
    return int(found.group(1)) if found else None


def memory(package=PACKAGE, renderer_pids=()):
    return {"app_pss_kb": pss_kb(package), "renderer_pss_kb": pss_kb(renderer_pids[0]) if renderer_pids else None}


def sockets(package=PACKAGE, onionoo=True):
    """check_sockets.py's classification; with Tor on, railgun-host and
    unexplained must both be 0."""
    args = [sys.executable, "-I", os.path.join(HERE, "check_sockets.py")]
    if onionoo:
        args.append("--onionoo")
    args.append(package)
    result = subprocess.run(args, capture_output=True, text=True, timeout=600)
    lines = result.stdout.splitlines()
    counts = None
    for line in lines:
        found = re.match(r"uid \d+: (\{.*\})$", line.strip())
        if found:
            counts = ast.literal_eval(found.group(1))
    if counts is None:
        raise RuntimeError(f"check_sockets.py gave no counts: {result.stderr.strip()[-300:]}")
    return {"counts": counts, "lines": [l.strip() for l in lines if not l.startswith("uid ")], "exit": result.returncode, "stderr": result.stderr.strip()[-500:]}


def screenshot(path):
    data = adb("exec-out", "screencap", "-p", binary=True)
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def probe(checks, vm_service_port=None, onionoo=True):
    result = {"at": now()}
    rend = renderers()
    if "renderer" in checks:
        result["renderer"] = rend
    if "listen" in checks:
        result["listen"] = listeners(vm_service_port=vm_service_port)
    if "mem" in checks:
        result["mem"] = memory(renderer_pids=rend["pids"])
    if "sockets" in checks:
        result["sockets"] = sockets(onionoo=onionoo)
    return result


def erc20_balance(rpc, token, address):
    """`balanceOf(address)` of the ERC-20 `token`, over JSON-RPC at `rpc`."""
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", token) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", address):
        raise ValueError("token and address must be 0x addresses")
    if not rpc.startswith("https://"):
        raise ValueError("the RPC must be https")
    data = "0x70a08231" + address[2:].lower().rjust(64, "0")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": token, "data": data}, "latest"]}).encode()
    request = urllib.request.Request(rpc, data=body, headers={"Content-Type": "application/json", "User-Agent": "vizor-device-round/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        answer = json.loads(response.read())
    if "result" not in answer:
        raise RuntimeError(f"eth_call failed: {answer.get('error')}")
    return int(answer["result"], 16)


def append_jsonl(path, record):
    with open(path, "a") as f:
        f.write(json.dumps(record) + "\n")


# ── serve: the checkpoint driver ─────────────────────────────────────────


def serve(port, out):
    os.makedirs(out, exist_ok=True)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            sys.stdout.write(f"{now()} driver {fmt % args}\n")
            sys.stdout.flush()

        def reply(self, payload, status=200):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                return self.reply({"ok": True})
            self.reply({"error": "not found"}, 404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            try:
                request = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self.reply({"error": "bad json"}, 400)
            try:
                if self.path == "/checkpoint":
                    name = str(request.get("name", "unnamed"))
                    checks = request.get("checks") or ["renderer", "listen", "mem", "sockets"]
                    result = probe(checks, vm_service_port=request.get("vmServicePort"), onionoo=request.get("onionoo", True))
                    result["name"] = name
                    result["note"] = request.get("note")
                    with lock:
                        append_jsonl(os.path.join(out, "checkpoints.jsonl"), result)
                    print(f"{now()} checkpoint {name}: {summary_line(result)}", flush=True)
                    return self.reply(result)
                if self.path == "/event":
                    record = {"at": now(), **request}
                    with lock:
                        append_jsonl(os.path.join(out, "events.jsonl"), record)
                    print(f"{now()} event {json.dumps(request)}", flush=True)
                    return self.reply({"ok": True})
                if self.path == "/erc20-balance":
                    # The M7 round's withdrawal check: a public balance on
                    # the deployment's keyless RPC, nothing secret.
                    balance = erc20_balance(str(request["rpc"]), str(request["token"]), str(request["address"]))
                    return self.reply({"balance": str(balance)})
                if self.path == "/screenshot":
                    name = re.sub(r"[^A-Za-z0-9_.-]", "_", str(request.get("name", "shot")))
                    size = screenshot(os.path.join(out, f"{name}.png"))
                    return self.reply({"ok": True, "bytes": size})
            except Exception as error:  # Report it to the test rather than hang it.
                return self.reply({"error": f"{type(error).__name__}: {error}"}, 500)
            self.reply({"error": "not found"}, 404)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"{now()} driver listening on 127.0.0.1:{port}, evidence in {out}", flush=True)
    server.serve_forever()


def summary_line(result):
    parts = []
    if "renderer" in result:
        parts.append(f"renderer={'pid ' + ','.join(map(str, result['renderer']['pids'])) if result['renderer']['running'] else 'none'}")
    if "listen" in result:
        parts.append(f"listen_other={result['listen']['other_ports']} rows={result['listen']['count']}")
    if "mem" in result:
        parts.append(f"app_pss_kb={result['mem']['app_pss_kb']} renderer_pss_kb={result['mem']['renderer_pss_kb']}")
    if "sockets" in result:
        parts.append(f"sockets={result['sockets']['counts']}")
    return " ".join(parts)


# ── release-check: drive an installed build from the host ────────────────


def ui_nodes():
    """The screen's accessibility nodes. Flutter puts a semantics label in
    `text` or `content-desc`, and may merge a card's texts into one node, so
    each node keeps both strings, and callers match within them."""
    try:
        shell(f"uiautomator dump {UI_DUMP}", timeout=60)
        raw = adb("exec-out", "cat", UI_DUMP, binary=True)
        root = ElementTree.fromstring(raw)
    except (RuntimeError, ElementTree.ParseError, subprocess.TimeoutExpired):
        return []
    nodes = []
    for node in root.iter("node"):
        found = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.attrib.get("bounds", ""))
        if not found:
            continue
        x1, y1, x2, y2 = map(int, found.groups())
        labels = [v for v in (node.attrib.get("text", ""), node.attrib.get("content-desc", "")) if v]
        nodes.append({"labels": labels, "label": " | ".join(labels), "center": ((x1 + x2) // 2, (y1 + y2) // 2)})
    return nodes


def find(nodes, predicate):
    return next((n for n in nodes if any(predicate(l) for l in n["labels"])), None)


def search(nodes, pattern):
    """The first match of [pattern] in any node's strings."""
    for node in nodes:
        for label in node["labels"]:
            found = re.search(pattern, label)
            if found:
                return found.group(0)
    return None


def wait_for(predicate, description, timeout, log, interval=1.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        nodes = ui_nodes()
        node = find(nodes, predicate)
        if node:
            return node, nodes
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {description}")


def tap(node):
    x, y = node["center"]
    shell(f"input tap {x} {y}")


def parse_updated(text, year):
    found = re.search(r"Updated (\d{1,2}) (\w{3}), (\d{2}):(\d{2})", text)
    if not found or found.group(2) not in MONTHS:
        return None
    day, month, hour, minute = int(found.group(1)), MONTHS[found.group(2)], int(found.group(3)), int(found.group(4))
    return datetime.datetime(year, month, day, hour, minute)


def release_check(out, passcode, timeout):
    os.makedirs(out, exist_ok=True)
    log_path = os.path.join(out, "release-check.log")
    record_path = os.path.join(out, "release-checkpoints.jsonl")

    def log(line):
        line = f"{now()} {line}"
        print(line, flush=True)
        with open(log_path, "a") as f:
            f.write(line + "\n")

    def checkpoint(name, checks=("renderer", "listen", "mem")):
        result = probe(list(checks))
        result["name"] = name
        append_jsonl(record_path, result)
        log(f"checkpoint {name}: {summary_line(result)}")
        return result

    verdict = {"loaded": False, "renderer_seen": False, "bridge_seen": False, "error_text": None, "statuses": []}
    shell(f"am force-stop {PACKAGE}")
    adb("logcat", "-c")
    logcat = subprocess.Popen([ADB, "logcat", "-v", "threadtime"], stdout=open(os.path.join(out, "release-logcat.txt"), "w"), stderr=subprocess.STDOUT)
    try:
        shell("input keyevent KEYCODE_WAKEUP")
        device_epoch = int(shell("date +%s").strip())
        launched = datetime.datetime.fromtimestamp(device_epoch)
        log(f"launching {ACTIVITY} (device time {launched:%H:%M:%S})")
        shell(f"am start -W -n {ACTIVITY}")
        node, _ = wait_for(lambda l: l.strip() == "Digit 1", "the passcode keypad", 120, log)
        screenshot(os.path.join(out, "release-01-unlock.png"))
        for digit in passcode:
            key, _ = wait_for(lambda l, d=digit: l.strip() == f"Digit {d}", f"digit {digit}", 30, log, interval=0.3)
            tap(key)
            time.sleep(0.3)
        log("passcode entered")
        strip, _ = wait_for(lambda l: "Open private USD" in l, "the home Private USD strip", 120, log)
        log(f"home strip: {strip['label']!r}")
        time.sleep(3)
        screenshot(os.path.join(out, "release-02-home.png"))
        before = checkpoint("release-home-before-open")
        opened_at = time.time()
        tap(strip)
        wait_for(lambda l: "Your receive address" in l or "0zkUSDC held on Ethereum" in l, "/private-usd", 60, log)
        log("/private-usd is showing")
        screenshot(os.path.join(out, "release-03-private-usd-open.png"))
        last_status, saw_busy, last_probe = None, False, 0.0
        deadline = time.time() + timeout
        while time.time() < deadline:
            nodes = ui_nodes()
            status = search(nodes, r"Updated \d{1,2} \w{3}, \d{2}:\d{2}|Updating…|Loading your private balance(: \d+%)?")
            error = search(nodes, r"Couldn't (update|load) the balance")
            if status != last_status:
                log(f"status: {status!r}")
                verdict["statuses"].append({"at": now(), "status": status, "s": round(time.time() - opened_at, 1)})
                last_status = status
            if status and (status.startswith("Updating") or status.startswith("Loading")):
                saw_busy = True
            if error:
                verdict["error_text"] = error
                log(f"error line: {error!r}")
            if time.time() - last_probe > 10:
                last_probe = time.time()
                result = checkpoint(f"release-open-{int(time.time() - opened_at)}s")
                verdict["renderer_seen"] |= result["renderer"]["running"]
                verdict["bridge_seen"] |= bool(result["listen"]["other_ports"])
            updated = parse_updated(status or "", launched.year)
            floor = launched.replace(second=0, microsecond=0)
            # A sync stamped after the launch, seen finishing or in a later minute.
            if updated and ((saw_busy and updated >= floor) or updated > floor):
                verdict["loaded"] = True
                verdict["seconds_to_updated"] = round(time.time() - opened_at, 1)
                break
            time.sleep(1.0)
        screenshot(os.path.join(out, "release-04-private-usd-after.png"))
        after = checkpoint("release-after-refresh")
        verdict["renderer_seen"] |= after["renderer"]["running"]
        verdict["bridge_seen"] |= bool(after["listen"]["other_ports"])
        # A release build has no Dart VM service: before first use, no listener at all.
        verdict["listen_before_open"] = before["listen"]["rows"]
        verdict["no_listener_before_open"] = not before["listen"]["rows"]
        verdict["renderer_before_open"] = before["renderer"]["running"]
    except Exception as error:  # Recorded in the verdict; the round goes on.
        verdict["error"] = f"{type(error).__name__}: {error}"
        log(f"release check failed: {verdict['error']}")
        try:
            screenshot(os.path.join(out, "release-99-failure.png"))
        except Exception:
            pass
    finally:
        time.sleep(2)
        logcat.terminate()
    crashes = []
    with open(os.path.join(out, "release-logcat.txt"), errors="replace") as f:
        for line in f:
            if any(p in line for p in CRASH_PATTERNS) and ("vizor" in line or "AndroidRuntime" in line or "FATAL" in line):
                crashes.append(line.rstrip())
    verdict["crash_lines"] = crashes[:50]
    verdict["passed"] = bool(verdict["loaded"] and verdict["renderer_seen"] and verdict["bridge_seen"] and not crashes and not verdict["error_text"] and not verdict.get("error"))
    with open(os.path.join(out, "release-verdict.json"), "w") as f:
        json.dump(verdict, f, indent=2)
    log(f"verdict: {json.dumps({k: v for k, v in verdict.items() if k not in ('statuses', 'listen_before_open')})}")
    return 0 if verdict["passed"] else 1


# ── summarize ────────────────────────────────────────────────────────────


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def summarize(out):
    digest = {}
    peaks = {}
    for name in ("sample-mem.txt", "release-sample-mem.txt"):
        path = os.path.join(out, name)
        if not os.path.exists(path):
            continue
        app = [int(m) for m in re.findall(r"app_pss_kb=(\d+)", open(path).read())]
        rend = [int(m) for m in re.findall(r"renderer_pss_kb=(\d+)", open(path).read())]
        peaks[name] = {"samples": len(app), "peak_app_pss_mb": round(max(app) / 1024, 1) if app else None, "peak_renderer_pss_mb": round(max(rend) / 1024, 1) if rend else None}
    digest["memory"] = peaks
    for name in ("sample-sockets.txt", "release-sample-sockets.txt"):
        path = os.path.join(out, name)
        if not os.path.exists(path):
            continue
        samples = [ast.literal_eval(m) for m in re.findall(r"uid \d+: (\{.*\})", open(path).read())]
        totals = {}
        for sample in samples:
            for key, value in sample.items():
                totals[key] = totals.get(key, 0) + value
        digest[name] = {"samples": len(samples), "totals": totals, "samples_with_railgun_host": sum(1 for s in samples if s.get("railgun-host")), "samples_with_unexplained": sum(1 for s in samples if s.get("unexplained"))}
    digest["events"] = read_jsonl(os.path.join(out, "events.jsonl"))
    digest["checkpoints"] = [
        {"name": c["name"], "at": c["at"], "summary": summary_line(c)} for c in read_jsonl(os.path.join(out, "checkpoints.jsonl"))
    ]
    verdict_path = os.path.join(out, "release-verdict.json")
    if os.path.exists(verdict_path):
        digest["release"] = json.load(open(verdict_path))
    for what in ("app-files", "logs"):
        scan_path = os.path.join(out, f"{KEYED_RPC_SCAN_PREFIX}{what}.json")
        if os.path.exists(scan_path):
            scanned = json.load(open(scan_path))
            digest[f"keyed_rpc_{what}"] = {k: scanned.get(k) for k in ("verdict", "files", "matches", "error")}
    print(json.dumps(digest, indent=2))


# ── keyed-rpc-check / keyed-rpc-scan: the keyed RPC never leaks (M8.3) ──

# The defines and the hosts the app accepts for each (reference §7.3;
# `privateUsdKeyedRpcUrl` drops any other host).
KEYED_RPC_DEFINES = {
    "sepolia": ("VIZOR_ETHEREUM_RPC_URL_SEPOLIA", {"eth-sepolia.g.alchemy.com", "sepolia.infura.io"}),
    "mainnet": ("VIZOR_ETHEREUM_RPC_URL_MAINNET", {"eth-mainnet.g.alchemy.com", "mainnet.infura.io"}),
}
KEYED_RPC_SCAN_PREFIX = "keyed-rpc-scan-"
# What `--app-files` reads: the Private USD directory and token state, and
# the app's SharedPreferences (relative to the app's data directory).
APP_FILES_FIND = r"find . -type f \( -path '*private_usd*' -o -path './shared_prefs/*' \)"


class KeyedRpcError(Exception):
    """A check that could not run. Its message never quotes a URL."""


def keyed_rpc_needles(path):
    """[(label, bytes)] to look for, per keyed URL in the define file: its
    host and path (also JSON-escaped, as org.json writes `/`), and each path or
    query part long enough to be its key. Only the labels ever leave here."""
    try:
        with open(path, "rb") as f:
            defines = json.loads(f.read())
    except (OSError, ValueError):
        raise KeyedRpcError("the define file is not readable JSON") from None
    if not isinstance(defines, dict):
        raise KeyedRpcError("the define file is not a JSON object")
    needles = {}
    for network, (define, hosts) in KEYED_RPC_DEFINES.items():
        value = defines.get(define)
        if value is None or (isinstance(value, str) and not value.strip()):
            continue
        if not isinstance(value, str):
            raise KeyedRpcError(f"{define} is not a string")
        try:
            parts = urllib.parse.urlsplit(value.strip())
            port = parts.port
        except ValueError:
            raise KeyedRpcError(f"{define} is not a URL") from None
        if parts.scheme != "https" or parts.hostname not in hosts or port not in (None, 443):
            raise KeyedRpcError(f"{define} must be https on {' or '.join(sorted(hosts))}; the app drops any other URL")
        keys = [part for part in re.split(r"[/?&=;]", f"{parts.path}?{parts.query}") if len(part) >= 12]
        if not keys:
            raise KeyedRpcError(f"{define} has no key in its path or query")
        host_path = f"{parts.netloc}{parts.path}" + (f"?{parts.query}" if parts.query else "")
        needles[network] = [
            (f"{network} host+path", host_path.encode()),
            (f"{network} host+path (JSON-escaped)", host_path.replace("/", "\\/").encode()),
            *[(f"{network} key" + (f" {i + 1}" if len(keys) > 1 else ""), key.encode()) for i, key in enumerate(keys)],
        ]
    if not needles:
        raise KeyedRpcError("the define file sets no keyed RPC URL")
    return needles


def keyed_rpc_check(path, require):
    try:
        needles = keyed_rpc_needles(path)
    except KeyedRpcError as error:
        print(f"keyed RPC: {error}", file=sys.stderr)
        return 2
    if require and require not in needles:
        print(f"keyed RPC: the round runs on {require}: set {KEYED_RPC_DEFINES[require][0]}", file=sys.stderr)
        return 2
    for network, items in needles.items():
        host = urllib.parse.urlsplit(json.load(open(path))[KEYED_RPC_DEFINES[network][0]].strip()).hostname
        print(f"keyed RPC: {network} on {host}; {len(items)} patterns to look for")
    return 0


def scan(data, needles):
    """{label: count} of the needles found in data."""
    return {label: data.count(needle) for label, needle in needles if needle in data}


def app_files(package=PACKAGE):
    """(path, bytes) of each file APP_FILES_FIND lists, read with run-as into
    memory and checked against its size. Raises when anything is unreadable."""
    listing = shell(f"run-as {package} {APP_FILES_FIND}")
    paths = sorted(line.strip() for line in listing.splitlines() if line.strip().startswith("./"))
    if not paths:
        raise KeyedRpcError(f"run-as found no Private USD file or preference in {package}")
    sizes = {}
    stat = shell(f"run-as {package} stat -c '%s %n' " + " ".join(shlex.quote(p) for p in paths))
    for line in stat.splitlines():
        size, _, name = line.strip().partition(" ")
        if size.isdigit():
            sizes[name] = int(size)
    for path in paths:
        for attempt in range(2):
            data = adb("exec-out", f"run-as {package} cat {shlex.quote(path)}", binary=True, timeout=600)
            if path not in sizes or len(data) == sizes[path]:
                break
            if attempt:
                raise KeyedRpcError(f"{path}: read {len(data)} bytes of {sizes[path]}")
        yield path, data


def keyed_rpc_scan(path, out, what):
    """Scans the app's files or the round's logs; writes the verdict."""
    record = {"what": what, "verdict": "error", "patterns": [], "files": 0, "bytes": 0, "matches": []}
    try:
        groups = keyed_rpc_needles(path)
        needles = [needle for items in groups.values() for needle in items]
        record["patterns"] = [label for label, _ in needles]
        if what == "app-files":
            sources = app_files()
        else:
            sources = (
                (entry.name, open(entry.path, "rb").read())
                for entry in sorted(os.scandir(out), key=lambda e: e.name)
                if entry.is_file(follow_symlinks=False) and not entry.name.startswith(KEYED_RPC_SCAN_PREFIX)
            )
        for name, data in sources:
            record["files"] += 1
            record["bytes"] += len(data)
            if what == "app-files" and name.endswith("/swaps.db"):
                record["swaps_db"] = True
            for label, count in scan(data, needles).items():
                record["matches"].append({"file": name, "pattern": label, "count": count})
        if record["files"] == 0:
            raise KeyedRpcError("nothing to scan")
        record["verdict"] = "found" if record["matches"] else "clean"
    except (KeyedRpcError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        # adb's own messages quote only the command, never file contents.
        record["error"] = f"{type(error).__name__}: {error}"
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, f"{KEYED_RPC_SCAN_PREFIX}{what}.json"), "w") as f:
        json.dump(record, f, indent=2)
    summary = f"{record['files']} files, {record['bytes'] / 1e6:.1f} MB, {len(record['patterns'])} patterns"
    if record["verdict"] == "clean":
        if what == "app-files" and not record.get("swaps_db"):
            summary += "; no swaps.db yet (no conversion on this wallet)"
        print(f"keyed RPC scan ({what}): clean; {summary}")
        return 0
    if record["verdict"] == "found":
        for match in record["matches"]:
            print(f"keyed RPC scan ({what}): FOUND {match['pattern']} in {match['file']} (x{match['count']})")
        return 1
    print(f"keyed RPC scan ({what}): could not check: {record['error']}", file=sys.stderr)
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--port", type=int, required=True)
    serve_parser.add_argument("--out", required=True)
    release_parser = sub.add_parser("release-check")
    release_parser.add_argument("--out", required=True)
    release_parser.add_argument("--passcode", required=True, help="the throwaway test wallet's passcode")
    release_parser.add_argument("--timeout", type=int, default=600)
    probe_parser = sub.add_parser("probe")
    probe_parser.add_argument("--onionoo", action="store_true")
    summarize_parser = sub.add_parser("summarize")
    summarize_parser.add_argument("--out", required=True)
    check_parser = sub.add_parser("keyed-rpc-check")
    check_parser.add_argument("--file", required=True)
    check_parser.add_argument("--require", choices=sorted(KEYED_RPC_DEFINES))
    scan_parser = sub.add_parser("keyed-rpc-scan")
    scan_parser.add_argument("--file", required=True)
    scan_parser.add_argument("--out", required=True)
    scan_what = scan_parser.add_mutually_exclusive_group(required=True)
    scan_what.add_argument("--app-files", action="store_true")
    scan_what.add_argument("--logs", action="store_true")
    args = parser.parse_args()
    local = args.command in ("summarize", "keyed-rpc-check") or (args.command == "keyed-rpc-scan" and args.logs)
    if not local and not os.environ.get("ANDROID_SERIAL"):
        sys.exit("set ANDROID_SERIAL")
    if args.command == "serve":
        serve(args.port, args.out)
    elif args.command == "release-check":
        sys.exit(release_check(args.out, args.passcode, args.timeout))
    elif args.command == "probe":
        print(json.dumps(probe(["renderer", "listen", "mem", "sockets"], onionoo=args.onionoo), indent=2))
    elif args.command == "summarize":
        summarize(args.out)
    elif args.command == "keyed-rpc-check":
        sys.exit(keyed_rpc_check(args.file, args.require))
    elif args.command == "keyed-rpc-scan":
        sys.exit(keyed_rpc_scan(args.file, args.out, "app-files" if args.app_files else "logs"))


if __name__ == "__main__":
    main()
