#!/usr/bin/env python3
"""Check Shielded USD's Railgun page process in a Linux bundle and its AppImage.

The page process loads the system's WebKitGTK at run time and runs on the
system's libraries alone (linux/runner/CMakeLists.txt; AGENTS.md, "Private
USD"): nothing in the bundle or the AppImage may link WebKit, libsoup or
JavaScriptCore or carry a copy of them, and the page process has no RPATH. The
page's own files must be in the bundle's data/railgun.

usage: check_railgun_page.py <bundle dir> [<AppImage>]
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

PAGE = "veylor-railgun-page"
WEBKIT = ("libwebkit2gtk", "libjavascriptcoregtk", "libsoup")
PAGE_FILES = ("index.html", "railgun.js", "poseidon_hash_wasm_bg.wasm", "curve25519_scalarmult_wasm_bg.wasm")


def dynamic(path: Path) -> str:
    return subprocess.run(
        ["readelf", "--wide", "--dynamic", str(path)], capture_output=True, text=True, check=False
    ).stdout


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def check_tree(root: Path, page: Path) -> list[str]:
    failures = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(root)
        if path.name.startswith(WEBKIT):
            failures.append(f"carries {relative}")
        if not is_elf(path):
            continue
        for needed in re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic(path)):
            if needed.startswith(WEBKIT):
                failures.append(f"{relative} links {needed}")
    if not page.is_file():
        failures.append(f"no {page.relative_to(root)}")
    else:
        if re.search(r"\((RPATH|RUNPATH)\)", dynamic(page)):
            failures.append(f"{page.relative_to(root)} has a library path")
        if not os.access(page, os.X_OK):
            failures.append(f"{page.relative_to(root)} is not executable")
    return failures


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    bundle = Path(sys.argv[1]).resolve()
    failures = [f"bundle: {failure}" for failure in check_tree(bundle, bundle / PAGE)]
    for name in PAGE_FILES:
        if not (bundle / "data" / "railgun" / name).is_file():
            failures.append(f"bundle: no data/railgun/{name}")
    if len(sys.argv) == 3:
        appimage = Path(sys.argv[2]).resolve()
        with tempfile.TemporaryDirectory(prefix="veylor-appimage-check-") as temporary:
            subprocess.run(
                [str(appimage), "--appimage-extract"], cwd=temporary, check=True, capture_output=True,
                env=dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1"),
            )
            root = Path(temporary) / "squashfs-root"
            failures += [f"AppImage: {failure}" for failure in check_tree(root, root / "usr" / "bin" / PAGE)]
    for failure in failures:
        print(failure)
    print(f"Railgun page check: {'failed' if failures else 'passed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
