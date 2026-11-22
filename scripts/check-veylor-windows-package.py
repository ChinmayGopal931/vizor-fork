#!/usr/bin/env python3
"""Check a Veylor Windows build and its Velopack package carry Veylor's identity alone.

A public Veylor build must not show Vizor's identity anywhere (docs/releases.md,
"Desktop identity"): the executable's name and version resource, the package's
id, title, authors and files all name Veylor and Zapp LLC. It also checks the
settings the app compiled with (the defines' names and the few values that
matter; no keyed RPC URL), and that the Railgun page's bundle is in the app.

It reads every program and library in the app (PE files) too: each is built
for the package's architecture, and every DLL of the Visual C++ runtime one
imports is beside the app and in the package. Windows has none of them, only
the Visual C++ Redistributable, which a runner has and a fresh PC may lack: an
app without them doesn't start, and Velopack's installer reports that its
install hook failed (windows/CMakeLists.txt ships them).

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
import struct
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
# The Visual C++ runtime's DLLs, which only its redistributables put in Windows
# (debug ones included, which never ship): the C and C++ runtimes, older ones
# too, the concurrency runtime, C++/CX, OpenMP, C++ AMP and MFC. Windows's own
# msvcrt.dll has no digit after the name, and the Universal CRT is Windows's.
RUNTIME_DLL = re.compile(r"^(msvcp|msvcr|vcruntime|concrt|vccorlib|vcomp|vcamp|mfcm?)[0-9].*\.dll$", re.IGNORECASE)
MACHINES = {"x64": 0x8664, "arm64": 0xAA64}
MACHINE_NAMES = {0x14C: "x86", 0x8664: "x64", 0xAA64: "arm64"}


def pe_imports(path: Path) -> tuple[int, list[str]]:
    """The machine a PE file is built for, and the DLLs it imports, delay-loaded ones too."""
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError("no MZ header")
    (header,) = struct.unpack_from("<I", data, 0x3C)
    if data[header : header + 4] != b"PE\0\0":
        raise ValueError("no PE header")
    machine, section_count = struct.unpack_from("<HH", data, header + 4)
    (optional_size,) = struct.unpack_from("<H", data, header + 20)
    optional = header + 24
    (magic,) = struct.unpack_from("<H", data, optional)
    if magic == 0x20B:  # PE32+
        (image_base,) = struct.unpack_from("<Q", data, optional + 24)
        directories = optional + 112
    elif magic == 0x10B:  # PE32
        (image_base,) = struct.unpack_from("<I", data, optional + 28)
        directories = optional + 96
    else:
        raise ValueError(f"an optional header of kind {magic:#x}")
    (directory_count,) = struct.unpack_from("<I", data, directories - 4)
    (headers_size,) = struct.unpack_from("<I", data, optional + 60)
    # Each section's size in memory, address, size in the file and offset there.
    sections = [
        struct.unpack_from("<4I", data, optional + optional_size + 40 * index + 8) for index in range(section_count)
    ]

    def offset(rva: int) -> int:
        if rva < headers_size:
            return rva
        for memory_size, address, file_size, file_offset in sections:
            size = min(memory_size, file_size) if memory_size else file_size
            if address <= rva < address + size:
                return file_offset + rva - address
        raise ValueError(f"address {rva:#x} is in no section's data")

    def name_at(rva: int) -> str:
        start = offset(rva)
        return data[start : data.index(b"\0", start)].decode("ascii")

    def table(index: int) -> int | None:
        if index >= directory_count:
            return None
        (rva,) = struct.unpack_from("<I", data, directories + 8 * index)
        return offset(rva) if rva else None

    names = []
    # The import table: 20-byte entries, each DLL's name at 12, to an empty one.
    position = table(1)
    while position is not None:
        entry = struct.unpack_from("<5I", data, position)
        if not any(entry):
            break
        names.append(name_at(entry[3]))
        position += 20
    # The delay-load table: 32-byte entries, the name at 4, an address unless
    # the first field's lowest bit says it is relative.
    position = table(13)
    while position is not None:
        entry = struct.unpack_from("<8I", data, position)
        if not any(entry):
            break
        names.append(name_at(entry[1] if entry[0] & 1 else entry[1] - image_base))
        position += 32
    return machine, names


def file_versions(paths: list[Path]) -> dict[str, str]:
    script = (
        "Get-Item -LiteralPath "
        + ",".join(f"'{path}'" for path in paths)
        + " | ForEach-Object { $_.Name + '=' + $_.VersionInfo.FileVersion }"
    )
    out = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    return {name.lower(): version for name, _, version in (line.partition("=") for line in out.splitlines()) if version}


def runtime_needed(pack_dir: Path, arch: str, check) -> list[str]:
    """Checks every PE file in the app; returns the runtime DLLs they import."""
    beside = {path.name.lower(): path for path in pack_dir.iterdir() if path.is_file()}
    binaries = sorted(path for path in pack_dir.rglob("*") if path.is_file() and path.suffix.lower() in (".exe", ".dll"))
    needed: set[str] = set()
    unreadable, other_arch, no_imports = [], [], []
    print("programs and libraries, with the C++ runtime they import:")
    for binary in binaries:
        name = binary.relative_to(pack_dir).as_posix()
        try:
            machine, imports = pe_imports(binary)
        except (ValueError, struct.error, UnicodeDecodeError) as error:
            print(f"  {name}: unreadable ({error})")
            unreadable.append(name)
            continue
        runtime = sorted({dll.lower() for dll in imports if RUNTIME_DLL.match(dll)})
        print(f"  {name} ({MACHINE_NAMES.get(machine, hex(machine))}): {', '.join(runtime) or 'none'}")
        if machine != MACHINES[arch]:
            other_arch.append(name)
        # Every Windows program imports something (kernel32.dll at least): an
        # empty list would be a misread, which would pass unread.
        if not imports:
            no_imports.append(name)
        needed.update(runtime)
    check(bool(binaries) and not unreadable, f"every program and library reads as a PE file {unreadable}")
    check(not other_arch, f"every program and library is {arch} {other_arch}")
    check(not no_imports, f"every program and library's imports were read {no_imports}")
    shipped = sorted(name for name in beside if RUNTIME_DLL.match(name))
    versions = file_versions([beside[name] for name in shipped]) if shipped else {}
    print("the C++ runtime beside the app:", ", ".join(f"{name} {versions.get(name, '?')}" for name in shipped) or "none")
    for dll in sorted(needed):
        check(dll in beside, f"{dll} is beside the app")
    return sorted(needed)


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

    runtime = runtime_needed(args.pack_dir, args.arch, check)

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
            # What the installer puts beside the app: the package's lib/app.
            app_files = sorted(name[len("lib/app/") :] for name in names if re.fullmatch(r"lib/app/[^/]+", name))
            print("the package's app folder:", ", ".join(app_files))
            for dll in runtime:
                check(dll in {name.lower() for name in app_files}, f"the package carries {dll}")
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
