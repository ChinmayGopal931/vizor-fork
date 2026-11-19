"""Checks the appcast scripts/release-veylor-macos.sh generated before it ships.

The feed must offer exactly this release: the stable DMG asset under the
release's tag, its build and version, the app's minimum macOS (the rule
fastlane/common/sparkle_compatibility.rb holds upstream's feed to), signed
release notes of the right length, and an embedded feed signature, since
Veylor's app requires a signed feed. sign_update then verifies the EdDSA
signatures themselves.

  python3 -I check_appcast.py --appcast appcast.xml --dmg Veylor-macos.dmg \\
      --notes Veylor-macos.md --dmg-url URL --notes-url URL \\
      --version 0.9.0 --build 1 --minimum-system-version 12.0

It prints the DMG's and the notes' sparkle:edSignature values, one per line,
for sign_update --verify.
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fail(message):
    print(f"check_appcast: {message}", file=sys.stderr)
    sys.exit(1)


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def main():
    parser = argparse.ArgumentParser()
    for flag in ("appcast", "dmg", "notes", "dmg-url", "notes-url", "version", "build",
                 "minimum-system-version"):
        parser.add_argument(f"--{flag}", required=True)
    args = parser.parse_args()

    with open(args.appcast, "rb") as handle:
        raw = handle.read()
    if b"sparkle-signatures:" not in raw:
        fail("the feed carries no signature, and the app requires a signed feed")

    items = ET.fromstring(raw).findall("./channel/item")
    if len(items) != 1:
        fail(f"expected one item, found {len(items)}")
    item = items[0]

    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        fail(f"expected one enclosure, found {len(enclosures)}")
    enclosure = enclosures[0]
    if enclosure.get("url") != args.dmg_url:
        fail(f"the enclosure points at {enclosure.get('url')!r}, not {args.dmg_url!r}")
    if enclosure.get("length") != str(os.path.getsize(args.dmg)):
        fail("the enclosure length does not match the DMG")
    dmg_signature = enclosure.get(sparkle("edSignature"), "").strip()
    if not dmg_signature:
        fail("the enclosure has no sparkle:edSignature")

    def text(name):
        element = item.find(sparkle(name))
        return None if element is None else (element.text or "").strip()

    if text("version") != args.build:
        fail(f"sparkle:version is {text('version')!r}, not {args.build!r}")
    if text("shortVersionString") != args.version:
        fail(f"sparkle:shortVersionString is {text('shortVersionString')!r}, not {args.version!r}")
    minimums = item.findall(sparkle("minimumSystemVersion"))
    if len(minimums) != 1 or (minimums[0].text or "").strip() != args.minimum_system_version:
        fail(f"sparkle:minimumSystemVersion must be the app's {args.minimum_system_version}")

    links = item.findall(sparkle("releaseNotesLink"))
    if len(links) != 1:
        fail(f"expected one sparkle:releaseNotesLink, found {len(links)}")
    link = links[0]
    if link.text != args.notes_url:
        fail(f"the release notes link is {link.text!r}, not {args.notes_url!r}")
    notes_signature = link.get(sparkle("edSignature"), "").strip()
    if not notes_signature:
        fail("the release notes link has no sparkle:edSignature")
    if link.get(sparkle("length")) != str(os.path.getsize(args.notes)):
        fail("the release notes length does not match the notes file")

    print(dmg_signature)
    print(notes_signature)


if __name__ == "__main__":
    main()
