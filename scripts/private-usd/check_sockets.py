#!/usr/bin/env python3
"""Classify an Android app's TCP sockets: loopback, Railgun hosts, Tor relays, other.

Private USD device rounds use it to check that, with Tor on, the Railgun page's
traffic leaves the phone only through Tor (docs/private-usd-android-plan.md
§10). `ss -tnp` needs root on user builds, so it reads the app UID's rows in
/proc/net/tcp{,6} through adb instead.

Usage: ANDROID_SERIAL=<serial> scripts/private-usd/check_sockets.py [--onionoo] [package]

Railgun host IPs are resolved both on this machine and on the device, because
CDNs answer differently per resolver. With --onionoo, every other remote IP is
looked up in the Tor Project's relay directory. With Tor on, "railgun-host"
and "unexplained" must both be 0; the exit status is 1 otherwise.
"""
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import urllib.request

# The page's allowlist (rust/src/railgun_bridge.rs, RailgunEndpoints.hosts, the page CSP).
HOSTS = [
    "ethereum-rpc.publicnode.com",
    "ethereum-sepolia-rpc.publicnode.com",
    "eth-mainnet.g.alchemy.com",
    "eth-sepolia.g.alchemy.com",
    "mainnet.infura.io",
    "sepolia.infura.io",
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    "ipfs-lb.com",
]
STATES = {"01": "ESTABLISHED", "02": "SYN_SENT", "03": "SYN_RECV", "06": "TIME_WAIT", "08": "CLOSE_WAIT"}


def adb_shell(command):
    adb = os.path.join(os.environ.get("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk")), "platform-tools", "adb")
    return subprocess.run([adb, "shell", command], capture_output=True, text=True).stdout


def decode(hex_addr):
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


def is_relay(ip):
    try:
        url = f"https://onionoo.torproject.org/summary?search={ip}"
        with urllib.request.urlopen(url, timeout=20) as response:
            return bool(json.load(response).get("relays"))
    except Exception:
        return None


def app_uid(package):
    for line in adb_shell(f"dumpsys package {package}").splitlines():
        for key in ("userId=", "appId="):
            if key in line:
                return line.split(key)[1].split()[0]
    return None


def railgun_ips():
    ips = {}
    for host in HOSTS:
        try:
            for info in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP):
                ips[ipaddress.ip_address(info[4][0])] = host
        except socket.gaierror:
            pass
        found = re.search(r"\(([0-9a-fA-F:.]+)\)", adb_shell(f"ping -c 1 -W 1 {host}"))
        if found:
            ips[ipaddress.ip_address(found.group(1))] = host
    return ips


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    package = args[0] if args else "com.keplr.vizor"
    onionoo = "--onionoo" in sys.argv
    uid = app_uid(package)
    if uid is None:
        sys.exit(f"{package} is not installed")
    railgun = railgun_ips()
    counts = {"loopback": 0, "railgun-host": 0, "tor-relay": 0, "unexplained": 0}
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in adb_shell(f"cat {table}").splitlines()[1:]:
            cols = line.split()
            if len(cols) < 8 or cols[7] != uid or cols[3] not in STATES:
                continue
            ip, port = decode(cols[2])
            state = STATES[cols[3]]
            if ip.is_loopback or ip.is_unspecified:
                counts["loopback"] += 1
            elif ip in railgun:
                counts["railgun-host"] += 1
                print(f"  DIRECT  {railgun[ip]} {ip}:{port} {state}")
            elif onionoo and is_relay(ip):
                counts["tor-relay"] += 1
                print(f"  relay   {ip}:{port} {state}")
            else:
                counts["unexplained"] += 1
                print(f"  other   {ip}:{port} {state}")
    print(f"uid {uid}: {counts}")
    sys.exit(1 if counts["railgun-host"] or (onionoo and counts["unexplained"]) else 0)


main()
