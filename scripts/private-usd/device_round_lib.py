"""Shared helpers for the Private USD device round drivers.

`device_round.py` (Android), `ios/device_round_ios.py` and `check_sockets.py`
import it. They run under `python3 -I`, which leaves the script's directory
off `sys.path`, so each puts this directory there before importing.
"""
import datetime
import ipaddress
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CHECKS = ["renderer", "listen", "mem", "sockets"]


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


def append_jsonl(path, record):
    with open(path, "a") as f:
        f.write(json.dumps(record) + "\n")


def railgun_hosts():
    """The page's allowlist, from Rust's `deployment::RAILGUN_PAGE_HOSTS`."""
    with open(os.path.join(REPO, "rust", "src", "wallet", "private_usd", "deployment.rs")) as f:
        source = f.read()
    found = re.search(r"RAILGUN_PAGE_HOSTS: \[&str; \d+\] = \[(.*?)\];", source, re.S)
    if not found:
        raise RuntimeError("RAILGUN_PAGE_HOSTS not found in deployment.rs")
    hosts = re.findall(r'"([^"]+)"', re.sub(r"//[^\n]*", "", found.group(1)))
    if not hosts:
        raise RuntimeError("RAILGUN_PAGE_HOSTS is empty")
    return hosts


def railgun_ips(hosts):
    """{ip: host} for every address this machine resolves `hosts` to."""
    ips = {}
    for host in hosts:
        try:
            for info in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP):
                ips[ipaddress.ip_address(info[4][0])] = host
        except socket.gaierror:
            pass
    return ips


_relays = {}


def is_relay(ip):
    """Whether the Tor Project's relay directory lists `ip`; None when it can't tell."""
    key = str(ip)
    if key not in _relays:
        try:
            with urllib.request.urlopen(f"https://onionoo.torproject.org/summary?search={key}", timeout=20) as response:
                _relays[key] = bool(json.load(response).get("relays"))
        except Exception:
            _relays[key] = None
    return _relays[key]


def proc_net_address(hex_addr):
    """The (ip, port) of an address column of /proc/net/tcp{,6}."""
    addr, port = hex_addr.split(":")
    raw = bytes.fromhex(addr)
    if len(raw) == 4:
        ip = ipaddress.IPv4Address(raw[::-1])
    else:
        # Four little-endian 32-bit words.
        words = [raw[i:i + 4][::-1] for i in range(0, 16, 4)]
        ip = ipaddress.IPv6Address(b"".join(words))
        if ip.ipv4_mapped:
            ip = ip.ipv4_mapped
    return ip, int(port, 16)


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


def summary_line(result):
    parts = []
    for key in CHECKS:
        section = result.get(key)
        if section is None:
            continue
        if section.get("measured") is False:
            parts.append(f"{key}=unmeasured")
        elif key == "renderer":
            parts.append(f"renderer={'pid ' + ','.join(map(str, section['pids'])) if section['running'] else 'none'}")
        elif key == "listen":
            parts.append(f"listen_other={section['other_ports']} rows={section['count']}")
        elif key == "mem":
            kind = section.get("kind", "pss")
            parts.append(f"app_{kind}_kb={section['app_pss_kb']} renderer_{kind}_kb={section['renderer_pss_kb']}")
        else:
            parts.append(f"sockets={section['counts']}")
    return " ".join(parts)


def serve(port, out, probe, screenshot, bind="127.0.0.1", token=""):
    """The checkpoint driver integration_test/private_usd_device_test.dart calls.

    `probe(checks, vm_service_port, onionoo)` takes a checkpoint, and
    `screenshot(path)` saves one, returning its size or None when the host
    can't take one. With a token, it answers only under /t/<token>/, and the
    token stays out of its log.
    """
    os.makedirs(out, exist_ok=True)
    prefix = f"/t/{token}" if token else ""
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            line = fmt % args
            sys.stdout.write(f"{now()} driver {line.replace(token, '<token>') if token else line}\n")
            sys.stdout.flush()

        def reply(self, payload, status=200):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def route(self):
            if not self.path.startswith(prefix + "/"):
                return None
            return self.path[len(prefix):]

        def do_GET(self):
            if self.route() == "/health":
                return self.reply({"ok": True})
            self.reply({"error": "not found"}, 404)

        def do_POST(self):
            path = self.route()
            if path is None:
                return self.reply({"error": "not found"}, 404)
            length = int(self.headers.get("Content-Length") or 0)
            try:
                request = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self.reply({"error": "bad json"}, 400)
            try:
                if path == "/checkpoint":
                    name = str(request.get("name", "unnamed"))
                    checks = request.get("checks") or CHECKS
                    result = probe(checks, request.get("vmServicePort"), request.get("onionoo", True))
                    result["name"] = name
                    with lock:
                        append_jsonl(os.path.join(out, "checkpoints.jsonl"), result)
                    print(f"{now()} checkpoint {name}: {summary_line(result)}", flush=True)
                    return self.reply(result)
                if path == "/event":
                    # The epoch places the event against a packet capture's times.
                    record = {"at": now(), "epoch": time.time(), **request}
                    with lock:
                        append_jsonl(os.path.join(out, "events.jsonl"), record)
                    print(f"{now()} event {json.dumps(request)}", flush=True)
                    return self.reply({"ok": True})
                if path == "/erc20-balance":
                    # A public balance on the deployment's keyless RPC, nothing secret.
                    balance = erc20_balance(str(request["rpc"]), str(request["token"]), str(request["address"]))
                    return self.reply({"balance": str(balance)})
                if path == "/screenshot":
                    name = re.sub(r"[^A-Za-z0-9_.-]", "_", str(request.get("name", "shot")))
                    size = screenshot(os.path.join(out, f"{name}.png"))
                    # A screenshot the host can't take never fails the round.
                    return self.reply({"ok": size is not None, "bytes": size})
            except Exception as error:  # Report it to the test rather than hang it.
                return self.reply({"error": f"{type(error).__name__}: {error}"}, 500)
            self.reply({"error": "not found"}, 404)

    server = ThreadingHTTPServer((bind, port), Handler)
    print(f"{now()} driver listening on {bind}:{port}{' under a token' if token else ''}, evidence in {out}", flush=True)
    server.serve_forever()
