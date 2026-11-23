#!/usr/bin/env python3
"""Check Windows's Railgun page host against the hosts checklist, on Windows, spending nothing.

docs/private-usd-railgun-hosts.md, section 7: the host's own page code
(windows/runner/railgun, built into windows/runner/tests/railgun_page's check
program) loads the real bundle in WebView2, with a stand-in for the Rust bridge:
a loopback SOCKS5 server that accepts what the bridge accepts (no auth,
CONNECT, a hostname on 443, the page's hosts), logs each CONNECT, and forwards
it. The page opens BIP-39's public test wallet; nothing is spent, and no
mnemonic, key or page message is printed.

  supported    the system's WebView2 Runtime is there and new enough
  environment  the page's origin and world (secure context, crypto.subtle,
               WebAssembly, IndexedDB, localStorage, a module worker from blob:),
               its timers while shown, its fixed User-Agent and no client
               hints, its quota, the filter refusing a host the CSP allows, the
               CSP refusing one it doesn't, the archive answered by the host for
               the page's origin, and an allowed host reached through the
               stand-in, with the headers on the wire
  sync         a Sepolia first sync to `synced`, the note-key workers, and every
               connection through the stand-in, by name (with --firewall, the
               WebView2 Runtime's programs may reach nothing but loopback)
  reopen       the store kept: the same wallet opens from IndexedDB
  reload       a page, closed, then one on another bridge in the same process
               (as after a route change), each reaching the RPC through its
               own, and the store wiped there
  archive      a mainnet start with the archive: the page asks the host for it
  wipe         the store deleted whole

usage: check_railgun_page.py --check <railgun_page_check.exe> --bundle <dir>
                             [--work <dir>] [--report <json>] [--firewall]
                             [--modes supported,environment,sync,reopen,reload,archive,wipe] [--expect-library]

Beside the wallet library (`rust_lib_zcash_wallet.dll` next to the check
program) the archive is fetched for real, through the stand-in; without it
every archive request is the host's own 502, and nothing dials the archive.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
ENDPOINTS = REPO / "linux/runner/railgun_page/railgun_endpoints.h"
TEST_MNEMONIC = " ".join(["abandon"] * 11 + ["about"])
SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
MAINNET_RPC = "https://ethereum-rpc.publicnode.com"
# A host the CSP allows that the check program has the filter refuse.
REFUSED_HOST = "ppoi.fdi.network"
ARCHIVE_HOST = "digest.anon.inc"
LABEL = re.compile(r"^[a-z0-9]+(-+[a-z0-9]+)*$", re.IGNORECASE)


def page_accept_language() -> str:
    """The one language the page names on every host (android/railgun-web/src/accept-language.js)."""
    source = (REPO / "android/railgun-web/src/accept-language.js").read_text(encoding="utf-8")
    match = re.search(r"export const ACCEPT_LANGUAGE = '([^']+)';", source)
    if not match:
        sys.exit("accept-language.js has no ACCEPT_LANGUAGE")
    return match.group(1)


def page_hosts() -> list[str]:
    source = ENDPOINTS.read_text(encoding="utf-8")
    body = source.split("kHosts[] = {", 1)[1].split("};", 1)[0]
    return re.findall(r'"([^"]+)"', body)


def allowed(host: str, hosts: list[str]) -> bool:
    for pattern in hosts:
        if pattern.startswith("*."):
            suffix = pattern[1:]
            if len(host) > len(suffix) and host.lower().endswith(suffix.lower()):
                if all(LABEL.match(label) for label in host[: -len(suffix)].split(".")):
                    return True
        elif host.lower() == pattern.lower():
            return True
    return False


class StandIn:
    """A SOCKS5 stand-in for the Rust bridge, which logs every CONNECT."""

    def __init__(self, hosts: list[str]):
        self.hosts = hosts
        self.connects: list[dict] = []
        self.lock = threading.Lock()
        self.loop = asyncio.new_event_loop()
        self.port = 0
        ready = threading.Event()
        self.thread = threading.Thread(target=self._run, args=(ready,), daemon=True)
        self.thread.start()
        ready.wait(10)

    def _run(self, ready: threading.Event) -> None:
        asyncio.set_event_loop(self.loop)
        server = self.loop.run_until_complete(asyncio.start_server(self._serve, "127.0.0.1", 0))
        self.port = server.sockets[0].getsockname()[1]
        ready.set()
        self.loop.run_forever()

    def log(self, entry: dict) -> None:
        entry["t"] = round(time.time(), 3)
        with self.lock:
            self.connects.append(entry)

    def since(self, mark: float) -> list[dict]:
        with self.lock:
            return [entry for entry in self.connects if entry["t"] >= mark]

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        entry: dict = {}
        try:
            version, count = await reader.readexactly(2)
            methods = await reader.readexactly(count)
            if version != 5 or 0 not in methods:
                writer.write(b"\x05\xff")
                return
            writer.write(b"\x05\x00")
            _, command, _, atyp = await reader.readexactly(4)
            host = None
            if atyp == 3:
                length = (await reader.readexactly(1))[0]
                host = (await reader.readexactly(length)).decode("ascii", "replace")
            elif atyp == 1:
                await reader.readexactly(4)
            elif atyp == 4:
                await reader.readexactly(16)
            port = int.from_bytes(await reader.readexactly(2), "big")
            entry = {"atyp": atyp, "host": host, "port": port, "command": command}
            refusal = None
            if command != 1:
                refusal = 0x07
            elif atyp != 3:
                refusal = 0x08
            elif port != 443 or not allowed(host or "", self.hosts):
                refusal = 0x02
            if refusal is not None:
                entry["refused"] = refusal
                self.log(entry)
                writer.write(bytes([5, refusal, 0, 1, 0, 0, 0, 0, 0, 0]))
                return
            upstream_reader, upstream_writer = await asyncio.wait_for(asyncio.open_connection(host, 443), 15)
            self.log(entry)
            writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()

            async def pipe(source: asyncio.StreamReader, sink: asyncio.StreamWriter) -> None:
                try:
                    while chunk := await source.read(65536):
                        sink.write(chunk)
                        await sink.drain()
                finally:
                    sink.close()

            await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer), return_exceptions=True)
        except Exception as error:  # noqa: BLE001 - a stand-in logs and drops what fails
            if entry:
                entry["error"] = type(error).__name__
        finally:
            try:
                writer.close()
            except Exception:  # noqa: BLE001
                pass


def powershell(script: str) -> str:
    return subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    ).stdout


def webview_sockets(owner: int) -> dict:
    """The TCP connections and UDP endpoints of the WebView2 processes the check program `owner` started.

    Only the page's own: its browser process is the check program's child, and the browser's renderer, GPU,
    network and crash processes are its children. Other apps' WebView2 (Widgets, Search) talk to Microsoft directly
    and are counted apart, as `others`.
    """
    out = powershell(
        "$all = @(Get-CimInstance Win32_Process -Filter \"Name = 'msedgewebview2.exe'\" -ErrorAction SilentlyContinue);"
        f"$parents = @([uint32]{int(owner)}); $ids = @();"
        "for ($depth = 0; $depth -lt 4; $depth++) {"
        " $children = @($all | Where-Object { ($parents -contains $_.ParentProcessId) -and ($ids -notcontains $_.ProcessId) } |"
        "   ForEach-Object { [uint32]$_.ProcessId });"
        " if ($children.Count -eq 0) { break }; $ids += $children; $parents = $children"
        "};"
        "$others = $all.Count - $ids.Count;"
        "if ($ids.Count -gt 0) {"
        " $tcp = @(Get-NetTCPConnection -OwningProcess $ids -ErrorAction SilentlyContinue |"
        "   Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State);"
        " $udp = @(Get-NetUDPEndpoint -OwningProcess $ids -ErrorAction SilentlyContinue |"
        "   Select-Object LocalAddress,LocalPort);"
        " @{processes=$ids.Count; others=$others; tcp=$tcp; udp=$udp} | ConvertTo-Json -Compress -Depth 4"
        "} else { @{processes=0; others=$others; tcp=@(); udp=@()} | ConvertTo-Json -Compress -Depth 4 }"
    ).strip()
    try:
        sample = json.loads(out or "{}")
    except json.JSONDecodeError:
        return {"processes": 0, "tcp": [], "udp": [], "unreadable": True}
    for key in ("tcp", "udp"):
        value = sample.get(key) or []
        sample[key] = value if isinstance(value, list) else [value]
    return sample


class Firewall:
    """With --firewall: the WebView2 Runtime's programs may reach nothing but loopback."""

    RULE = "Veylor Railgun page check"

    def __init__(self) -> None:
        self.programs: list[str] = []
        self.active = False

    def block(self) -> None:
        roots = [os.environ.get("ProgramFiles(x86)", ""), os.environ.get("ProgramFiles", "")]
        for root in filter(None, roots):
            base = Path(root) / "Microsoft" / "EdgeWebView" / "Application"
            if base.is_dir():
                self.programs += [str(path) for path in base.glob("*/msedgewebview2.exe")]
        if not self.programs:
            return
        remote = "1.0.0.0-126.255.255.255,128.0.0.0-255.255.255.255,::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
        lines = ["Set-NetFirewallProfile -All -Enabled True"]
        for program in self.programs:
            lines.append(
                f"New-NetFirewallRule -DisplayName '{self.RULE}' -Direction Outbound -Action Block "
                f"-Program '{program}' -RemoteAddress {remote} | Out-Null"
            )
        lines.append(f"@(Get-NetFirewallRule -DisplayName '{self.RULE}' -ErrorAction SilentlyContinue).Count")
        count = powershell("; ".join(lines)).strip().splitlines()
        self.active = bool(count) and count[-1].strip().isdigit() and int(count[-1].strip()) > 0

    def lift(self) -> None:
        if self.programs:
            powershell(f"Remove-NetFirewallRule -DisplayName '{self.RULE}' -ErrorAction SilentlyContinue")


class Run:
    def __init__(self, args: argparse.Namespace, stand_in: StandIn):
        self.args = args
        self.stand_in = stand_in
        self.failures: list[str] = []
        self.report: dict = {"modes": {}}

    def check(self, condition: bool, what: str) -> None:
        if not condition:
            self.failures.append(what)
            print(f"  FAIL {what}", flush=True)
        else:
            print(f"  ok   {what}", flush=True)

    def mode(self, name: str, mode: str, data: Path, extra: list[str], sample_sockets: bool = False) -> dict:
        print(f"== {name}", flush=True)
        command = [
            str(self.args.check),
            "--mode", mode,
            "--bundle", str(self.args.bundle),
            "--data", str(data),
            "--proxy-port", str(self.stand_in.port),
            *extra,
        ]
        mark = time.time()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        samples: list[dict] = []
        if sample_sockets:
            def sample() -> None:
                while process.poll() is None:
                    samples.append(webview_sockets(process.pid))
                    time.sleep(5)

            sampler = threading.Thread(target=sample, daemon=True)
            sampler.start()
        stdout, stderr = process.communicate(timeout=self.args.timeout)
        steps = []
        for line in stdout.splitlines():
            try:
                steps.append(json.loads(line))
            except json.JSONDecodeError:
                steps.append({"unreadable": line[:200]})
        result = {
            "exit": process.returncode,
            "steps": steps,
            "connects": self.stand_in.since(mark),
            "stderr": stderr[-2000:],
        }
        if sample_sockets:
            result["sockets"] = samples
        for step in steps:
            summary = {key: value for key, value in step.items() if key not in ("value", "requests")}
            print(f"  {json.dumps(summary)}", flush=True)
        self.report["modes"][name] = result
        return result


def step(result: dict, name: str) -> dict:
    for entry in result["steps"]:
        if entry.get("step") == name:
            return entry
    return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--work", type=Path, default=Path(os.environ.get("RUNNER_TEMP", ".")) / "railgun-page-check")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--firewall", action="store_true")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--modes", default="supported,environment,sync,reopen,reload,archive,wipe")
    # The wallet library is beside the check program (the package job's run): the archive must go through its fetch.
    parser.add_argument("--expect-library", action="store_true")
    args = parser.parse_args()
    modes = set(args.modes.split(","))

    hosts = page_hosts()
    stand_in = StandIn(hosts)
    run = Run(args, stand_in)
    shutil.rmtree(args.work, ignore_errors=True)
    args.work.mkdir(parents=True)
    key = secrets.token_hex(32)
    firewall = Firewall()

    try:
        if "supported" in modes:
            supported = run.mode("supported", "supported", args.work / "unused", [])
            run.report["runtime"] = step(supported, "supported").get("runtime")
            run.check(step(supported, "supported").get("value") is True, "the WebView2 Runtime is here and new enough")

        if "environment" in modes:
            environment = run.mode(
                "environment",
                "environment",
                args.work / "environment",
                ["--rpc", SEPOLIA_RPC, "--blocked-host", REFUSED_HOST],
            )
            run.check(step(environment, "load").get("ok") is True, "the page loads and says it is ready")
            value = step(environment, "environment").get("value") or {}
            run.check(value.get("origin") == "veylor-railgun://app", "the page's origin is veylor-railgun://app")
            run.check(value.get("secure") is True, "a secure context")
            for feature in ("subtle", "wasm", "wasmInstantiate", "localStorage", "indexedDB", "worker"):
                run.check(value.get(feature) is True, f"{feature} works")
            run.check(value.get("userAgent") == "Mozilla/5.0", "the page's User-Agent is Mozilla/5.0")
            run.check(value.get("userAgentData") in (None, "[]"), "no User-Agent client hints in the page")
            run.check(value.get("visibility") == "visible", "the page is visible while its window shows")
            run.check((value.get("timerTicks") or 0) >= 100, "the page's timers run unthrottled while shown")
            # The page's own estimate reports its usage plus 10 GiB (Chromium's StaticStorageQuota); DevTools reads
            # the quota Chromium enforces.
            total = shutil.disk_usage(args.work).total
            quota = step(environment, "quota").get("quota") or 0
            run.report["quota_ratio"] = round(quota / total, 3) if total else None
            run.report["reported_quota_ratio"] = round((value.get("quota") or 0) / total, 3) if total else None
            run.check(quota >= 0.5 * total, f"the origin may keep at least half the disk ({run.report['quota_ratio']})")
            connects = environment["connects"]
            run.check(value.get("refused", {}).get("failed") is not None, "the filter refuses a host the CSP allows")
            run.check(all(entry.get("host") != REFUSED_HOST for entry in connects), "a refused host is never dialled")
            run.check(value.get("forbidden", {}).get("failed") is not None, "the CSP refuses a host off its list")
            run.check(all(entry.get("host") != "example.com" for entry in connects), "a forbidden host is never dialled")
            run.check("status" in (value.get("archive") or {}), "the host answers the archive for the page's origin")
            run.check(value.get("allowed", {}).get("status") == 200, "an allowed host answers through the stand-in")
            sent = step(environment, "headers").get("requests") or []
            lowered = [{name.lower(): str(val) for name, val in headers.items()} for headers in sent]
            run.report["header_names"] = sorted({name for headers in lowered for name in headers})
            run.check(bool(lowered), "DevTools saw the page's requests on the wire")
            run.check(
                all(headers.get("user-agent") == "Mozilla/5.0" for headers in lowered if "user-agent" in headers),
                "every request's User-Agent is Mozilla/5.0",
            )
            run.check(
                not any(name.startswith("sec-ch-ua") for headers in lowered for name in headers),
                "no request sends User-Agent client hints",
            )
            # The page sets its one language on its own requests, on every host, and Windows's environment language
            # (en-US) gives Chromium's own header the same value: every request that names one names it.
            accept_language = page_accept_language()
            languages = sorted({headers["accept-language"] for headers in lowered if "accept-language" in headers})
            run.report["accept_languages"] = languages
            run.report["navigator_languages"] = value.get("languages")
            run.check(languages == [accept_language], f"every request's Accept-Language is {accept_language}")

        if args.firewall:
            firewall.block()
            run.report["firewall"] = {"active": firewall.active, "programs": len(firewall.programs)}
            run.check(firewall.active, "the WebView2 Runtime may reach nothing but loopback")

        if "sync" in modes:
            sync = run.mode(
                "sync",
                "sync",
                args.work / "store",
                ["--network", "sepolia", "--rpc", SEPOLIA_RPC, "--mnemonic", TEST_MNEMONIC, "--key", key,
                 "--seconds", "900"],
                sample_sockets=True,
            )
            for name in ("load", "start", "openWallet", "refresh"):
                run.check(step(sync, name).get("ok") is True, f"sync: {name}")
            run.check(step(sync, "event").get("ok") is True, "sync: the rest of the sync ends with `synced`")
            keys = step(sync, "noteKeysCounts").get("value") or {}
            run.report["note_keys"] = keys
            run.check((keys.get("workers") or 0) > 0 and (keys.get("prepared") or 0) > 0, "the note-key workers ran")
            events = step(sync, "counts").get("events") or {}
            run.check(events.get("scan", 0) > 0 and events.get("refresh", 0) > 0, "scan and refresh events reach Dart")
            run.check(events.get("log", 0) == 0, "no log event from a page loaded without debug")
            connects = sync["connects"]
            run.report["sync_hosts"] = sorted({entry.get("host") or "?" for entry in connects})
            run.check(bool(connects), "the page's connections went through the stand-in")
            run.check(all(entry.get("atyp") == 3 for entry in connects), "every CONNECT names a host (SOCKS5 type 3)")
            run.check(all(entry.get("port") == 443 for entry in connects), "every CONNECT is to port 443")
            run.check(all("refused" not in entry for entry in connects), "the stand-in refused nothing")
            tcp = [conn for sample in sync.get("sockets", []) for conn in sample.get("tcp", [])]
            outside = [
                conn for conn in tcp
                if conn.get("RemoteAddress") not in ("127.0.0.1", "::1", "0.0.0.0", "::")
            ]
            udp = [endpoint for sample in sync.get("sockets", []) for endpoint in sample.get("udp", [])]
            run.report["sockets"] = {
                "samples": len(sync.get("sockets", [])),
                "processes": max((sample.get("processes") or 0 for sample in sync.get("sockets", [])), default=0),
                # Other apps' WebView2 processes on the runner, not sampled.
                "others": max((sample.get("others") or 0 for sample in sync.get("sockets", [])), default=0),
                "tcp": len(tcp),
                "outside_loopback": outside[:10],
                "udp": udp[:10],
            }
            run.check(bool(tcp), "the page's WebView2 processes' sockets were sampled")
            run.check(not outside, "the page's WebView2 processes held no TCP connection off loopback")
            run.check(not udp, "the page's WebView2 processes held no UDP socket")

        if "reopen" in modes:
            reopen = run.mode(
                "reopen",
                "reopen",
                args.work / "store",
                ["--network", "sepolia", "--rpc", SEPOLIA_RPC, "--mnemonic", TEST_MNEMONIC, "--key", key,
                 "--seconds", "600"],
            )
            databases = (step(reopen, "databases").get("value") or {}).get("databases") or []
            run.report["databases"] = databases
            run.check("level-js-railgun-sepolia" in databases, "the engine's IndexedDB is kept between runs")
            for name in ("start", "openWallet"):
                run.check(step(reopen, name).get("ok") is True, f"reopen: {name}")
            first = step(reopen, "refresh")
            if first.get("ok") is not True and first:
                # Tried again once, as the app's next refresh would (a root the RPC hadn't caught up to).
                run.report["reopen_retried"] = (first.get("error") or {}).get("message")
            run.check(first.get("ok") is True or step(reopen, "refresh again").get("ok") is True, "reopen: refresh")

        if "reload" in modes:
            second = StandIn(hosts)
            mark = time.time()
            reload = run.mode(
                "reload",
                "reload",
                args.work / "reload",
                ["--rpc", SEPOLIA_RPC, "--second-proxy-port", str(second.port)],
            )
            for name in ("first load", "second load", "wipe"):
                run.check(step(reload, name).get("ok") is True, f"reload: {name}")
            run.report["reload"] = {
                name: step(reload, name).get("ms") for name in ("first load", "second load", "wipe")
            }
            first = (step(reload, "first reach").get("value") or {}).get("status")
            again = (step(reload, "second reach").get("value") or {}).get("status")
            run.check(first == 200 and again == 200, "each page reaches the RPC")
            # The same host both times: a socket the first page pooled would carry the second's request with no
            # new CONNECT, through the first bridge's route (U19).
            rpc_host = "ethereum-sepolia-rpc.publicnode.com"
            run.check(any(entry.get("host") == rpc_host for entry in reload["connects"]), "the first page goes through the first bridge")
            second_hosts = {entry.get("host") for entry in second.since(mark)}
            run.check(rpc_host in second_hosts, "the second page goes through its own bridge")
            closed = (step(reload, "first close").get("epoch") or 0) / 1000
            late = [entry.get("host") for entry in run.stand_in.since(closed)] if closed else ["(no close time)"]
            run.report["reload"]["first_bridge_after_close"] = late
            run.check(not late, "nothing goes through the first bridge once its page closed")

        if "archive" in modes:
            archive = run.mode(
                "archive",
                "sync",
                args.work / "mainnet",
                ["--network", "mainnet", "--rpc", MAINNET_RPC, "--archive", "--mnemonic", TEST_MNEMONIC, "--key", key,
                 "--seconds", "90"],
            )
            run.check(step(archive, "start").get("ok") is True, "archive: a mainnet start with the archive")
            counts = step(archive, "counts").get("archive") or {}
            run.report["archive"] = counts
            run.check((counts.get("requests") or 0) > 0, "the page asks the host for Anon's archive")
            if args.expect_library:
                run.check(counts.get("available") is True, f"the wallet library's fetch is here ({counts.get('library')})")
            dialled = [entry for entry in archive["connects"] if entry.get("host") == ARCHIVE_HOST]
            run.report["archive_connections"] = len(dialled)
            if counts.get("available"):
                run.check((counts.get("successes") or 0) > 0, "the archive answers through the bridge")
                run.check(bool(dialled), "the archive's connections go through the stand-in by name")
            else:
                run.check(not dialled, "without the wallet library the archive is never dialled")

        if "wipe" in modes:
            wipe = run.mode("wipe", "wipe", args.work / "store", [])
            run.check(step(wipe, "wipe").get("ok") is True, "the store is deleted whole")
    finally:
        firewall.lift()

    run.report["failures"] = run.failures
    if args.report:
        args.report.write_text(json.dumps(run.report, indent=2), encoding="utf-8")
    print(f"{len(run.failures)} failure(s)", flush=True)
    return 1 if run.failures else 0


if __name__ == "__main__":
    sys.exit(main())
