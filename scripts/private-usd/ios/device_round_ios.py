#!/usr/bin/env python3
"""Host side of the Private USD device rounds on iOS.

`scripts/private-usd/ios/run_device_round.sh` drives it. Run it with `python3 -I`. A target is
`sim:<udid>` (a booted simulator) or `device:<udid>` (an iPhone paired with this Mac).

  serve --port P --out DIR --target T [--bind ADDR] [--token TOKEN] [--bundle-id ID]
        Checkpoint driver for integration_test/private_usd_device_test.dart, with the same
        endpoints and answers as the Android driver (scripts/private-usd/device_round.py).
        A simulator shares this Mac's loopback. An iPhone reaches the Mac over the local
        network, so for a device the driver binds the Mac's address and answers only under
        /t/<token>/.
  probe --target T [--bundle-id ID] [--onionoo]
        One sample of what `serve` checks, printed.
  app-check --device UDID --bundle-id ID
        Exits 0 when no app with that bundle ID is installed, or the installed one was built
        by a developer; 4 when it may be a real wallet (an App Store or TestFlight build), and
        2 when it can't tell. Prints nothing about the app's data.
  capture-verdict --pcap F --out DIR [--onionoo]
        An iPhone's sockets: reads the round's rvictl capture and its events, and looks at
        what the iPhone sent while Tor was on (from each tor-connected event to the next
        tor-off). A connection to a Railgun host, or a DNS query for one, fails the round.
        rvictl sees the whole iPhone, not only the app, so Tor relays, Apple's network
        (17.0.0.0/8) and the local network pass, and anything else is listed for review.
        Exit 0 clean, 1 found, 2 could not check.
  summarize --out DIR
        Digest of a round's evidence.
  token
        A random token for `serve --token`.

What a checkpoint can see. On the simulator the app is a process of this Mac: its loopback
listeners, its sockets and those of the simulator's WebKit processes (lsof), its WebContent
processes and memory (RSS). On an iPhone none of these are reachable: the listener, socket,
memory and renderer sections come back `measured: false`; the test then checks the page and
its bridge from the app, and capture-verdict judges the sockets.

The Railgun hosts are read from Rust's `deployment::RAILGUN_PAGE_HOSTS`, the allowlist's
source. Nothing here reads or prints wallet secrets; the test never sends any.

Unverified until the first device session: the simulator's launchd labels for WebKit's
processes, `devicectl`'s JSON field names, and `tcpdump` on rvi0.
"""
import argparse
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from device_round_lib import CHECKS, is_relay, now, railgun_hosts, railgun_ips  # noqa: E402
from device_round_lib import serve as serve_driver  # noqa: E402

BUNDLE_ID = "com.keplr.vizor"
APPLE = ipaddress.ip_network("17.0.0.0/8")


def run(args, timeout=120, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)[:100]} failed ({result.returncode}): {result.stderr.strip()[:300]}")
    return result


def parse_target(target):
    kind, _, udid = target.partition(":")
    if kind not in ("sim", "device") or not udid:
        raise ValueError("a target is sim:<udid> or device:<udid>")
    return kind, udid


# ── The simulator ────────────────────────────────────────────────────────


def sim_jobs(udid):
    """(pid, label) of the simulator's running launchd jobs."""
    out = run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"]).stdout
    jobs = []
    for line in out.splitlines()[1:]:
        cols = line.split(None, 2)
        if len(cols) == 3 and cols[0].isdigit():
            jobs.append((int(cols[0]), cols[2]))
    return jobs


def sim_app_pid(udid, bundle_id, jobs=None):
    for pid, label in jobs if jobs is not None else sim_jobs(udid):
        if label.startswith(f"UIKitApplication:{bundle_id}["):
            return pid
    return None


def sim_webkit(udid, jobs=None, kind="WebContent"):
    """Pids of the simulator's WebKit processes of one kind (WebContent, Networking)."""
    return sorted(pid for pid, label in (jobs if jobs is not None else sim_jobs(udid)) if f"WebKit.{kind}" in label)


def lsof_tcp(pids, listen):
    if not pids:
        return []
    args = ["lsof", "-nP", "-a", "-p", ",".join(map(str, pids)), "-iTCP"]
    if listen:
        args.append("-sTCP:LISTEN")
    out = run(args, check=False).stdout  # lsof exits 1 when nothing matches
    rows = []
    for line in out.splitlines()[1:]:
        cols = line.split()
        if len(cols) < 9:
            continue
        name = cols[8]
        state = cols[9].strip("()") if len(cols) > 9 else ""
        rows.append({"command": cols[0], "pid": int(cols[1]), "name": name, "state": state})
    return rows


def split_endpoint(endpoint):
    host, _, port = endpoint.rpartition(":")
    host = host.strip("[]")
    try:
        return ipaddress.ip_address(host), int(port)
    except ValueError:
        return None, int(port) if port.isdigit() else None


def sim_probe(udid, bundle_id, checks, vm_service_port, onionoo, hosts):
    jobs = sim_jobs(udid)
    app = sim_app_pid(udid, bundle_id, jobs)
    if app is None:
        raise RuntimeError(f"{bundle_id} is not running on simulator {udid}")
    renderers = sim_webkit(udid, jobs, "WebContent")
    result = {"at": now(), "epoch": time.time(), "target": "simulator", "app_pid": app}
    if "renderer" in checks:
        result["renderer"] = {"running": bool(renderers), "pids": renderers}
    if "listen" in checks:
        rows = []
        for row in lsof_tcp([app], listen=True):
            ip, port = split_endpoint(row["name"])
            label = "vm-service" if vm_service_port and port == vm_service_port else "other"
            rows.append({"ip": str(ip), "port": port, "loopback": bool(ip and ip.is_loopback), "label": label})
        other = [r for r in rows if r["label"] == "other"]
        result["listen"] = {"rows": rows, "other_ports": sorted({r["port"] for r in other}), "count": len(rows)}
    if "mem" in checks:
        def rss(pid):
            out = run(["ps", "-o", "rss=", "-p", str(pid)], check=False).stdout.strip()
            return int(out) if out.isdigit() else None

        # RSS, not Android's PSS: the simulator runs on this Mac's memory and is no evidence for a phone's.
        result["mem"] = {"app_pss_kb": rss(app), "renderer_pss_kb": rss(renderers[0]) if renderers else None, "kind": "rss"}
    if "sockets" in checks:
        # The page's connections come from WebKit's networking process, not the app: with the
        # proxy in force it reaches only the bridge, on loopback.
        pids = [app] + sim_webkit(udid, jobs, "Networking")
        railgun = railgun_ips(hosts)
        counts = {"loopback": 0, "railgun-host": 0, "tor-relay": 0, "unexplained": 0}
        lines = []
        for row in lsof_tcp(pids, listen=False):
            if "->" not in row["name"]:
                continue
            ip, port = split_endpoint(row["name"].split("->", 1)[1])
            if ip is None:
                continue
            if ip.is_loopback or ip.is_unspecified:
                counts["loopback"] += 1
            elif ip in railgun:
                counts["railgun-host"] += 1
                lines.append(f"DIRECT  {railgun[ip]} {ip}:{port} {row['state']} ({row['command']})")
            elif onionoo and is_relay(ip):
                counts["tor-relay"] += 1
            else:
                counts["unexplained"] += 1
                lines.append(f"other   {ip}:{port} {row['state']} ({row['command']})")
        result["sockets"] = {"counts": counts, "lines": lines}
    return result


# ── The iPhone ───────────────────────────────────────────────────────────


def devicectl_json(*args, timeout=120):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "out.json")
        run(["xcrun", "devicectl", *args, "--json-output", path], timeout=timeout)
        with open(path) as f:
            return json.load(f)


def device_probe(udid, checks):
    unmeasured = {"measured": False}
    result = {"at": now(), "epoch": time.time(), "target": "device"}
    if "renderer" in checks:
        result["renderer"] = {**unmeasured, "running": False, "pids": []}
    if "listen" in checks:
        result["listen"] = {**unmeasured, "rows": [], "other_ports": [], "count": 0}
    if "mem" in checks:
        result["mem"] = {**unmeasured, "app_pss_kb": None, "renderer_pss_kb": None}
    if "sockets" in checks:
        result["sockets"] = {**unmeasured, "counts": None, "lines": ["judged by capture-verdict"]}
    return result


def app_check(udid, bundle_id):
    """Never install over a real wallet."""
    try:
        answer = devicectl_json("device", "info", "apps", "--device", udid, "--bundle-id", bundle_id)
    except Exception as error:
        print(f"could not list the iPhone's apps: {error}", file=sys.stderr)
        return 2
    apps = [a for a in answer.get("result", {}).get("apps", []) if a.get("bundleIdentifier") == bundle_id]
    if not apps:
        print(f"{bundle_id} is not installed")
        return 0
    built_by_developer = apps[0].get("builtByDeveloper")
    if built_by_developer is True:
        print(f"{bundle_id} is a development build")
        return 0
    if built_by_developer is False:
        print(f"{bundle_id} is installed and was not built by a developer: it may be a real wallet")
        return 4
    print(f"could not tell how {bundle_id} was built (no builtByDeveloper field)", file=sys.stderr)
    return 2


def screenshot(kind, udid, path):
    if kind == "sim":
        run(["xcrun", "simctl", "io", udid, "screenshot", path])
        return os.path.getsize(path)
    # devicectl has no screenshot; libimobiledevice's does, when it is installed.
    if run(["which", "idevicescreenshot"], check=False).returncode == 0:
        run(["idevicescreenshot", "-u", udid, path])
        return os.path.getsize(path)
    return None


def probe(target, bundle_id, checks, vm_service_port=None, onionoo=True, hosts=None):
    kind, udid = parse_target(target)
    if kind == "sim":
        return sim_probe(udid, bundle_id, checks, vm_service_port, onionoo, hosts or railgun_hosts())
    return device_probe(udid, checks)


# ── serve ────────────────────────────────────────────────────────────────


def serve(port, out, target, bind, token, bundle_id):
    kind, udid = parse_target(target)
    hosts = railgun_hosts()
    serve_driver(
        port,
        out,
        lambda checks, vm_service_port, onionoo: probe(target, bundle_id, checks, vm_service_port, onionoo, hosts),
        lambda path: screenshot(kind, udid, path),
        bind=bind,
        token=token,
    )


# ── capture-verdict ──────────────────────────────────────────────────────


TOR_ON = re.compile(r"^(tor-connected|m8-.+-tor-connected)$")
TOR_OFF = re.compile(r"^(tor-off|m8-.+-tor-off)$")


def tor_windows(events):
    windows, start = [], None
    for event in sorted(events, key=lambda e: e.get("epoch", 0)):
        name, epoch = str(event.get("name", "")), event.get("epoch")
        if epoch is None:
            continue
        if TOR_ON.match(name) and start is None:
            start = epoch
        elif TOR_OFF.match(name) and start is not None:
            windows.append((start, epoch))
            start = None
    if start is not None:
        windows.append((start, float("inf")))
    return windows


PACKET = re.compile(r"^(\d+\.\d+) (IP6?) (\S+) > (\S+): (.*)$")


def endpoint_ip(text):
    # tcpdump -n writes a.b.c.d.port, or v6addr.port.
    address = text.rstrip(":").rsplit(".", 1)[0]
    try:
        return ipaddress.ip_address(address)
    except ValueError:
        return None


def capture_verdict(pcap, out, onionoo):
    try:
        events = [json.loads(line) for line in open(os.path.join(out, "events.jsonl"))]
    except OSError as error:
        print(f"no events: {error}", file=sys.stderr)
        return 2
    windows = tor_windows(events)
    hosts = railgun_hosts()
    railgun = railgun_ips(hosts)
    # Outgoing connection attempts, and any UDP but DNS's and NTP's (QUIC would go around a SOCKS proxy).
    packets = run(["tcpdump", "-n", "-tt", "-r", pcap,
                   "(tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn) or (udp and not port 53 and not port 123 and not port 5353)"],
                  timeout=600, check=False)
    if packets.returncode != 0 and not packets.stdout:
        print(f"tcpdump could not read {pcap}: {packets.stderr.strip()[:300]}", file=sys.stderr)
        return 2
    dns = run(["tcpdump", "-n", "-tt", "-r", pcap, "udp port 53"], timeout=600, check=False).stdout
    inside = lambda t: any(start <= t <= end for start, end in windows)
    found = {"railgun-host": [], "dns-leak": [], "tor-relay": 0, "apple": 0, "local": 0, "unexplained": {}}
    for line in packets.stdout.splitlines():
        match = PACKET.match(line.strip())
        if not match:
            continue
        stamp = float(match.group(1))
        if not inside(stamp):
            continue
        ip = endpoint_ip(match.group(4))
        if ip is None:
            continue
        if ip in railgun:
            found["railgun-host"].append(f"{match.group(1)} {railgun[ip]} {ip}")
        elif ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast:
            found["local"] += 1
        elif ip in APPLE:
            found["apple"] += 1
        elif onionoo and is_relay(ip):
            found["tor-relay"] += 1
        else:
            found["unexplained"][str(ip)] = found["unexplained"].get(str(ip), 0) + 1
    for line in dns.splitlines():
        stamp = line.split(" ", 1)[0]
        try:
            stamp = float(stamp)
        except ValueError:
            continue
        if inside(stamp) and any(f" {host}." in line for host in hosts):
            found["dns-leak"].append(line.strip()[:160])
    verdict = {
        "windows": [[start, None if end == float("inf") else end] for start, end in windows],
        "passed": bool(windows) and not found["railgun-host"] and not found["dns-leak"],
        **found,
    }
    with open(os.path.join(out, "capture-verdict.json"), "w") as f:
        json.dump(verdict, f, indent=1)
    print(json.dumps({k: v for k, v in verdict.items() if k != "unexplained"}))
    if found["unexplained"]:
        print(f"for review (the whole iPhone, not only the app): {found['unexplained']}")
    if not windows:
        print("no Tor window in the events: nothing to judge", file=sys.stderr)
        return 2
    return 0 if verdict["passed"] else 1


def summarize(out):
    def read_jsonl(name):
        path = os.path.join(out, name)
        return [json.loads(line) for line in open(path)] if os.path.exists(path) else []

    checkpoints = read_jsonl("checkpoints.jsonl")
    events = read_jsonl("events.jsonl")
    rss = [c["mem"]["app_pss_kb"] for c in checkpoints if (c.get("mem") or {}).get("app_pss_kb")]
    verdict_path = os.path.join(out, "capture-verdict.json")
    summary = {
        "checkpoints": len(checkpoints),
        "events": [e.get("name") for e in events],
        "peak_app_rss_mb": round(max(rss) / 1024, 1) if rss else None,
        "capture_verdict": json.load(open(verdict_path)).get("passed") if os.path.exists(verdict_path) else None,
    }
    print(json.dumps(summary, indent=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    serve_args = commands.add_parser("serve")
    serve_args.add_argument("--port", type=int, required=True)
    serve_args.add_argument("--out", required=True)
    serve_args.add_argument("--target", required=True)
    serve_args.add_argument("--bind", default="127.0.0.1")
    serve_args.add_argument("--token", default="")
    serve_args.add_argument("--bundle-id", default=BUNDLE_ID)
    probe_args = commands.add_parser("probe")
    probe_args.add_argument("--target", required=True)
    probe_args.add_argument("--bundle-id", default=BUNDLE_ID)
    probe_args.add_argument("--onionoo", action="store_true")
    check_args = commands.add_parser("app-check")
    check_args.add_argument("--device", required=True)
    check_args.add_argument("--bundle-id", default=BUNDLE_ID)
    verdict_args = commands.add_parser("capture-verdict")
    verdict_args.add_argument("--pcap", required=True)
    verdict_args.add_argument("--out", required=True)
    verdict_args.add_argument("--onionoo", action="store_true")
    summary_args = commands.add_parser("summarize")
    summary_args.add_argument("--out", required=True)
    commands.add_parser("token")
    args = parser.parse_args()

    if args.command == "serve":
        serve(args.port, args.out, args.target, args.bind, args.token, args.bundle_id)
    elif args.command == "probe":
        print(json.dumps(probe(args.target, args.bundle_id, CHECKS, onionoo=args.onionoo), indent=1))
    elif args.command == "app-check":
        sys.exit(app_check(args.device, args.bundle_id))
    elif args.command == "capture-verdict":
        sys.exit(capture_verdict(args.pcap, args.out, args.onionoo))
    elif args.command == "summarize":
        summarize(args.out)
    elif args.command == "token":
        print(secrets.token_hex(16))


if __name__ == "__main__":
    main()
