"""Packages a notarized Veylor.app into Veylor's DMG.

dmgbuild writes the window's layout (background, icon positions) straight into
the volume's .DS_Store, so nothing scripts Finder. The window is true black
behind the background picture too. The geometry matches
macos/Packaging/DMG/veylor/render-background.swift.

scripts/release-veylor-macos.sh runs this with its pinned virtualenv:
  python -I build_dmg.py --app Veylor.app --output Veylor-macos.dmg \\
      --volume-name Veylor --background macos/Packaging/DMG/veylor/background.png \\
      [--volume-icon Veylor.app/Contents/Resources/VeylorAppIcon.icns]
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

import dmgbuild
from ds_store import DSStore

# Points, top-left origin, as Finder lays out the window.
WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (600, 400)
ICON_SIZE = 96
TEXT_SIZE = 13
APP_ICON_CENTER = (160, 240)
APPLICATIONS_ICON_CENTER = (440, 240)

# Hidden entries the volume may keep at its top level.
ALLOWED_HIDDEN = {".DS_Store", ".background.tiff", ".VolumeIcon.icns"}
# Entries macOS may leave on a volume mounted read-write; never shipped.
SYSTEM_LEFTOVERS = (".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems")


def fail(message):
    print(f"build_dmg: {message}", file=sys.stderr)
    sys.exit(1)


def attach(image, *, readonly):
    command = [
        "/usr/bin/hdiutil", "attach", image,
        "-nobrowse", "-noverify", "-noautoopen", "-owners", "off",
        "-mountrandom", tempfile.gettempdir(), "-plist",
    ]
    if readonly:
        command.append("-readonly")
    output = subprocess.run(command, check=True, capture_output=True).stdout
    for entity in plistlib.loads(output)["system-entities"]:
        if entity.get("mount-point"):
            return entity["dev-entry"], entity["mount-point"]
    fail(f"hdiutil attached {image} without a mount point")


def detach(device):
    for attempt in range(6):
        result = subprocess.run(["/usr/bin/hdiutil", "detach", device, "-quiet"])
        if result.returncode == 0:
            return
        time.sleep(1 + attempt)
    subprocess.run(["/usr/bin/hdiutil", "detach", device, "-force", "-quiet"], check=True)


def build(args, rw_image):
    app_name = os.path.basename(os.path.normpath(args.app))
    settings = {
        "format": "UDRW",
        "filesystem": "HFS+",
        "files": [os.path.normpath(args.app)],
        "symlinks": {"Applications": "/Applications"},
        "icon": args.volume_icon,
        "background": args.background,
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "window_rect": (WINDOW_ORIGIN, WINDOW_SIZE),
        "default_view": "icon-view",
        "show_icon_preview": False,
        "arrange_by": None,
        "label_pos": "bottom",
        "text_size": TEXT_SIZE,
        "icon_size": ICON_SIZE,
        "icon_locations": {
            app_name: APP_ICON_CENTER,
            "Applications": APPLICATIONS_ICON_CENTER,
        },
    }
    # background.png and its background@2x.png become one HiDPI TIFF.
    dmgbuild.build_dmg(rw_image, args.volume_name, settings=settings, lookForHiDPI=True)


def finish_volume(rw_image):
    """Blackens the view behind the picture and drops system leftovers."""
    device, mount_point = attach(rw_image, readonly=False)
    try:
        with DSStore.open(os.path.join(mount_point, ".DS_Store"), "r+") as store:
            view = store["."]["icvp"]
            view["backgroundColorRed"] = 0.0
            view["backgroundColorGreen"] = 0.0
            view["backgroundColorBlue"] = 0.0
            store["."]["icvp"] = view
        for name in SYSTEM_LEFTOVERS:
            path = os.path.join(mount_point, name)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.lexists(path):
                os.remove(path)
        subprocess.run(["/bin/sync"], check=True)
    finally:
        detach(device)


def verify(args, image):
    info = subprocess.run(
        ["/usr/bin/hdiutil", "imageinfo", image], check=True, capture_output=True, text=True
    ).stdout
    if "Format: UDZO" not in info:
        fail("expected a UDZO image")
    if "Apple_HFS" not in info:
        fail("expected an HFS+ volume")

    app_name = os.path.basename(os.path.normpath(args.app))
    device, mount_point = attach(image, readonly=True)
    try:
        disk = plistlib.loads(
            subprocess.run(
                ["/usr/sbin/diskutil", "info", "-plist", mount_point],
                check=True, capture_output=True,
            ).stdout
        )
        volume_name = disk.get("VolumeName")
        if volume_name != args.volume_name:
            fail(f"expected the volume name {args.volume_name!r}, got {volume_name!r}")
        app = os.path.join(mount_point, app_name)
        if not os.path.isdir(app):
            fail(f"{app_name} is missing from the volume")
        if os.readlink(os.path.join(mount_point, "Applications")) != "/Applications":
            fail("the Applications link is missing")
        if not os.path.isfile(os.path.join(mount_point, ".background.tiff")):
            fail("the background is missing")
        view = DSStore.open(os.path.join(mount_point, ".DS_Store"), "r")
        with view:
            icvp = view["."]["icvp"]
            if icvp.get("backgroundType") != 2 or not icvp.get("backgroundImageAlias"):
                fail("the window has no background picture")
            locations = {
                name: view[name]["Iloc"] for name in (app_name, "Applications")
            }
        if locations[app_name] != APP_ICON_CENTER or locations["Applications"] != APPLICATIONS_ICON_CENTER:
            fail(f"unexpected icon positions {locations}")
        if args.volume_icon and not os.path.isfile(os.path.join(mount_point, ".VolumeIcon.icns")):
            fail("the volume icon is missing")
        hidden = sorted(n for n in os.listdir(mount_point) if n.startswith("."))
        unexpected = [n for n in hidden if n not in ALLOWED_HIDDEN]
        if unexpected:
            fail(f"unexpected hidden entries on the volume: {unexpected}")
        visible = sorted(n for n in os.listdir(mount_point) if not n.startswith("."))
        if visible != sorted([app_name, "Applications"]):
            fail(f"unexpected entries on the volume: {visible}")
        # The copy on the volume must still carry its signature and ticket.
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True
        )
        subprocess.run(
            ["/usr/bin/xcrun", "stapler", "validate", "-q", app], check=True
        )
        print(f"build_dmg: verified {os.path.basename(image)} (volume {volume_name!r}, hidden {hidden})")
    finally:
        detach(device)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--volume-name", required=True)
    parser.add_argument("--background", required=True)
    parser.add_argument("--volume-icon")
    args = parser.parse_args()

    if not os.path.isdir(args.app):
        fail(f"expected an app bundle at {args.app}")
    if not os.path.isfile(args.background):
        fail(f"missing background {args.background}")
    if args.volume_icon and not os.path.isfile(args.volume_icon):
        fail(f"missing volume icon {args.volume_icon}")

    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    if os.path.exists(output):
        os.remove(output)

    with tempfile.TemporaryDirectory(prefix="veylor-dmg.", dir=os.path.dirname(output)) as work:
        rw_image = os.path.join(work, "Veylor-rw.dmg")
        build(args, rw_image)
        finish_volume(rw_image)
        subprocess.run(
            [
                "/usr/bin/hdiutil", "convert", rw_image,
                "-format", "UDZO", "-imagekey", "zlib-level=9",
                "-ov", "-o", output, "-quiet",
            ],
            check=True,
        )
    verify(args, output)
    print(f"build_dmg: created {output}")


if __name__ == "__main__":
    main()
