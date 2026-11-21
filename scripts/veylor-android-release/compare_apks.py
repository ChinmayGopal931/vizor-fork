#!/usr/bin/env python3
"""Say how two builds of an APK differ, entry by entry.

    python3 -I scripts/veylor-android-release/compare_apks.py FIRST SECOND [--extract DIR]

Exits 0 when the two files are byte-identical and 1 otherwise, after listing
the entries only one has, the entries whose contents differ and the entries
whose contents match but whose ZIP metadata does not. --extract copies each
entry whose contents differ to DIR/first/<name> and DIR/second/<name>, for
diffoscope (.github/workflows/veylor-android.yml).
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys
import zipfile


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def metadata(info: zipfile.ZipInfo) -> dict[str, object]:
    return {
        "offset": info.header_offset,
        "method": info.compress_type,
        "compressed": info.compress_size,
        "extra": info.extra.hex(),
        "date_time": info.date_time,
        "external_attr": info.external_attr,
        "flag_bits": info.flag_bits,
    }


def extract(archive: zipfile.ZipFile, name: str, target: pathlib.Path) -> None:
    path = (target / name).resolve()
    if target.resolve() not in path.parents:
        raise SystemExit(f"refusing to extract {name!r} outside {target}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(archive.read(name))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("first", type=pathlib.Path)
    parser.add_argument("second", type=pathlib.Path)
    parser.add_argument("--extract", type=pathlib.Path, metavar="DIR")
    args = parser.parse_args()

    hashes = (sha256(args.first), sha256(args.second))
    for label, path, digest in (("first", args.first, hashes[0]), ("second", args.second, hashes[1])):
        print(f"{label}: {path} {path.stat().st_size} bytes sha256 {digest}")
    if hashes[0] == hashes[1]:
        print("The two APKs are byte-identical.")
        return 0

    with zipfile.ZipFile(args.first) as first, zipfile.ZipFile(args.second) as second:
        a = {info.filename: info for info in first.infolist()}
        b = {info.filename: info for info in second.infolist()}
        only_first = sorted(set(a) - set(b))
        only_second = sorted(set(b) - set(a))
        content = sorted(
            name for name in set(a) & set(b)
            if (a[name].CRC, a[name].file_size) != (b[name].CRC, b[name].file_size)
        )
        layout = sorted(
            name for name in set(a) & set(b)
            if name not in content and metadata(a[name]) != metadata(b[name])
        )
        common = set(a) & set(b)
        order_differs = (
            [i.filename for i in first.infolist() if i.filename in common]
            != [i.filename for i in second.infolist() if i.filename in common]
        )

        print(f"entries: {len(a)} and {len(b)}")
        for title, names in (
            ("only in the first", only_first),
            ("only in the second", only_second),
            ("contents differ", content),
        ):
            print(f"{title}: {len(names)}")
            for name in names:
                sizes = " / ".join(
                    str(archive[name].file_size) for archive in (a, b) if name in archive
                )
                print(f"  {name} ({sizes} bytes)")
        print(f"same contents, different ZIP metadata: {len(layout)}")
        for name in layout[:50]:
            ours, theirs = metadata(a[name]), metadata(b[name])
            fields = ", ".join(f"{key} {ours[key]} / {theirs[key]}" for key in ours if ours[key] != theirs[key])
            print(f"  {name}: {fields}")
        if order_differs:
            print("the entries are in a different order")
        if not (only_first or only_second or content or layout or order_differs):
            print("every entry matches; the bytes differ outside the entries "
                  "(signing block, central directory or end record)")

        if args.extract and content:
            for name in content:
                extract(first, name, args.extract / "first")
                extract(second, name, args.extract / "second")
            print(f"extracted {len(content)} differing entries to {args.extract}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
