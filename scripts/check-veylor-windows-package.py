#!/usr/bin/env python3
"""Check a Veylor Windows build and its Velopack package carry Veylor's identity alone.

A public Veylor build must not show Vizor's identity anywhere (docs/releases.md,
"Desktop identity"): the executable's name and version resource, the package's
id, title, authors and files all name Veylor and Zapp LLC. It also checks the
settings the app compiled with (the defines' names and the few values that
matter; no keyed RPC URL), and that the Railgun page's bundle is in the app.

usage: check-veylor-windows-package.py --pack-dir <runner Release dir>
           --output-dir <velopack output dir> --app-id <com.veylor.desktop[.testnet]>
           --arch <x64|arm64> --version <asset version> --build-number <n>
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

REPO = Path(__file__).resolve().parents[1]
IDENTITIES = {
    "com.veylor.desktop": {"title": "Veylor", "exe": "Veylor.exe", "network": "main", "channel": "mainnet"},
    "com.veylor.desktop.testnet": {
        "title": "Veylor Testnet",
        "exe": "VeylorTestnet.exe",
        "network": "test",
        "channel": "testnet",
    },
}
FOREIGN = re.compile(r"vizor|keplr", re.IGNORECASE)
PAGE_FILES = ("index.html", "railgun.js", "poseidon_hash_wasm_bg.wasm", "curve25519_scalarmult_wasm_bg.wasm")


def version_info(path: Path) -> dict:
    script = (
        f"$v = (Get-Item -LiteralPath '{path}').VersionInfo;"
        "@{CompanyName=$v.CompanyName; ProductName=$v.ProductName; FileDescription=$v.FileDescription;"
        " OriginalFilename=$v.OriginalFilename; InternalName=$v.InternalName; LegalCopyright=$v.LegalCopyright;"
        " FileVersion=$v.FileVersion} | ConvertTo-Json -Compress"
    )
    out = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return json.loads(out or "{}")


def dart_defines() -> dict[str, str]:
    config = (REPO / "windows/flutter/ephemeral/generated_config.cmake").read_text(encoding="utf-8")
    match = re.search(r'"DART_DEFINES=([^"]*)"', config)
    if not match:
        sys.exit("the generated config has no DART_DEFINES")
    defines = {}
    for item in filter(None, match.group(1).split(",")):
        key, _, value = base64.b64decode(item).decode().partition("=")
        defines[key] = value
    return defines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--app-id", required=True, choices=sorted(IDENTITIES))
    parser.add_argument("--arch", required=True, choices=("x64", "arm64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    args = parser.parse_args()
    identity = IDENTITIES[args.app_id]
    failures: list[str] = []

    def check(condition: bool, what: str) -> None:
        print(f"  {'ok  ' if condition else 'FAIL'} {what}", flush=True)
        if not condition:
            failures.append(what)

    defines = dart_defines()
    print("dart-defines:", ", ".join(sorted(defines)))
    check(defines.get("ZCASH_DEFAULT_NETWORK") == identity["network"], "the network")
    check(defines.get("VIZOR_PRIVATE_USD_ENABLED") == "true", "Shielded USD is compiled in")
    check(defines.get("VIZOR_RELEASE_VERSION") == args.version, "the release version")
    check(defines.get("VIZOR_RELEASE_BUILD_NUMBER") == args.build_number, "the build number")
    check(defines.get("VIZOR_FORM_FACTOR", "desktop") == "desktop", "the desktop form factor")
    check(not any(key.startswith("VIZOR_ETHEREUM_RPC_URL") for key in defines), "no keyed RPC URL")

    executables = sorted(path.name for path in args.pack_dir.glob("*.exe"))
    print("executables:", ", ".join(executables))
    check(identity["exe"] in executables, f"the app is {identity['exe']}")
    check(not any(FOREIGN.search(name) for name in executables), "no executable names Vizor")
    info = version_info(args.pack_dir / identity["exe"])
    print("version resource:", json.dumps(info))
    check(info.get("ProductName") == identity["title"], "the product name")
    check(info.get("FileDescription") == identity["title"], "the file description")
    check(info.get("CompanyName") == "com.veylor", "the company name (which names the data directories)")
    check(info.get("OriginalFilename") == identity["exe"], "the original file name")
    check("Zapp LLC" in (info.get("LegalCopyright") or ""), "the copyright holder")
    check(not any(FOREIGN.search(str(value or "")) for value in info.values()), "no field of it names Vizor")

    page = args.pack_dir / "data" / "railgun"
    check(all((page / name).is_file() for name in PAGE_FILES), "the Railgun page's bundle is in data\\railgun")

    channel = f"win-{args.arch}-{identity['channel']}"
    setup = args.output_dir / f"{args.app_id}-{channel}-Setup.exe"
    package = args.output_dir / f"{args.app_id}-{args.version}-{channel}-full.nupkg"
    outputs = sorted(path.name for path in args.output_dir.iterdir())
    print("outputs:", ", ".join(outputs))
    check(setup.is_file(), f"the installer {setup.name}")
    check(package.is_file(), f"the package {package.name}")
    check(not any(FOREIGN.search(name) for name in outputs), "no output names Vizor")
    if setup.is_file():
        setup_info = version_info(setup)
        print("installer version resource:", json.dumps(setup_info))
        check(not any(FOREIGN.search(str(value or "")) for value in setup_info.values()), "the installer names no Vizor")
    if package.is_file():
        with zipfile.ZipFile(package) as archive:
            names = archive.namelist()
            # The app's own files; Flutter's assets keep upstream's code names (`Vizor Korean UI`), which nothing shows.
            foreign = [name for name in names if FOREIGN.search(name) and "/flutter_assets/" not in name]
            check(not foreign, f"no file of the app in the package names Vizor {foreign[:5]}")
            nuspec = next((name for name in names if name.endswith(".nuspec")), None)
            check(nuspec is not None, "the package has a manifest")
            if nuspec:
                manifest = archive.read(nuspec).decode("utf-8", "replace")
                print("manifest:", re.sub(r"\s+", " ", manifest)[:800])
                check(f"<id>{args.app_id}</id>" in manifest, "the package id")
                check(f"<title>{identity['title']}</title>" in manifest, "the package title")
                check("<authors>Zapp LLC</authors>" in manifest, "the package authors")
                check(not FOREIGN.search(manifest), "the manifest names no Vizor")

    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
