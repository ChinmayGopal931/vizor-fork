#!/usr/bin/env python3
"""Classify an Android app's TCP sockets: loopback, Railgun hosts, Tor relays, other.

Private USD device rounds use it to check that, with Tor on, the Railgun page's
traffic leaves the phone only through Tor. `ss -tnp` needs root on user builds,
so it reads the app UID's rows in /proc/net/tcp{,6} through adb instead.

Usage: ANDROID_SERIAL=<serial> scripts/private-usd/check_sockets.py [--onionoo] [package]

The Railgun hosts are Rust's `deployment::RAILGUN_PAGE_HOSTS`. Their IPs are
resolved both on this machine and on the device, because CDNs answer
differently per resolver. With --onionoo, every other remote IP is looked up in
the Tor Project's relay directory. With Tor on, "railgun-host" and
"unexplained" must both be 0; the exit status is 1 otherwise.
"""
import ipaddress
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from device_round_lib import is_relay, proc_net_address, railgun_hosts, railgun_ips  # noqa: E402

STATES = {"01": "ESTABLISHED", "02": "SYN_SENT", "03": "SYN_RECV", "06": "TIME_WAIT", "08": "CLOSE_WAIT"}


def adb_shell(command):
    adb = os.path.join(os.environ.get("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk")), "platform-tools", "adb")
    return subprocess.run([adb, "shell", command], capture_output=True, text=True).stdout


def app_uid(package):
    for line in adb_shell(f"dumpsys package {package}").splitlines():
        for key in ("userId=", "appId="):
            if key in line:
                return line.split(key)[1].split()[0]
    return None


def device_ips(hosts):
    """{ip: host} as the device resolves `hosts`."""
    ips = {}
    for host in hosts:
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
    hosts = railgun_hosts()
    railgun = {**railgun_ips(hosts), **device_ips(hosts)}
    counts = {"loopback": 0, "railgun-host": 0, "tor-relay": 0, "unexplained": 0}
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        rows = adb_shell(f"cat {table}").splitlines()
        if not rows or "local_address" not in rows[0]:
            sys.exit(f"could not read {table}")
        for line in rows[1:]:
            cols = line.split()
            if len(cols) < 8 or cols[7] != uid or cols[3] not in STATES:
                continue
            ip, port = proc_net_address(cols[2])
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


if __name__ == "__main__":
    main()
