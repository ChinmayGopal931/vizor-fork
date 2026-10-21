#!/usr/bin/env python3
"""
rename_veylor.py -- branding-only rename of the wallet's VISIBLE name:
Vizor -> Veylor.  Idempotent (a second run changes nothing) and safe to re-run
on a merged tree.

What it changes (visible text only):
  * Dart string literals under lib/, test/ and integration_test/ (never comments,
    never identifiers, never URLs/paths/file-like tokens, never test descriptions);
  * user-visible strings in iOS Swift / Android Kotlin, iOS Info.plist, the Android
    manifest label and the Android store listing;
  * a few Rust error strings that reach the UI (needs a Rust rebuild + codegen check);
  * Markdown prose (README, CONTRIBUTING, SECURITY, AGENTS, docs/, release_notes/,
    the Rust module READMEs under rust/src) and the dev/payment_uri_demo.html text;
  * the exported file names people see in save/share dialogs (EXPLICIT_EDITS).

Manual decisions live in the policy block below (DESKTOP_DART_FILES, CHART_SKIP,
DART_KEEP_LITERALS, DART_KEEP_BEFORE, TEST_AMBIGUOUS_KEEP_FILES, TEST_OVERRIDES,
EXPLICIT_EDITS, CLIKE_KEEP).  Re-running on a merged tree converts new mentions with
the same rules; review the diff for new functional literals or test descriptions.

What it never changes: app/bundle ids, `vizor_*` keys/prefs/db/file names, `VIZOR_*`
build flags, any identifier or file name containing Vizor/vizor, anything inside a
URL/URI/host/scheme, code comments, doc comments, log lines, test descriptions,
network-protocol values, desktop packaging/update internals.

Scope switches:
  default             mobile + shared code (iOS/Android focus).  Desktop-only files are
                      skipped and counted (see DESKTOP_* below).  The portfolio-chart
                      feature's own files are skipped and counted (CHART_SKIP).
  --include-desktop   also process the desktop-only Dart files and the desktop native
                      user-visible strings (windows/, linux/, macos/).  Packaging
                      internals (PRODUCT_NAME, Vizor.app, .exe names, update feeds...)
                      are still never touched.

Usage:
  python3 rename_veylor.py --root /path/to/repo [--dry-run] [--include-desktop]
                           [--only dart,native,rust,docs,store] [--report out.json] [-v]
"""
from __future__ import annotations

import argparse
import collections
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

OLD, NEW = "Vizor", "Veylor"
OLD_UP, NEW_UP = "VIZOR", "VEYLOR"
OLD_LOW, NEW_LOW = "vizor", "veylor"

# ----------------------------------------------------------------------------
# POLICY
# ----------------------------------------------------------------------------

# The owner's "do not touch" list (plus generated files).
OFF_LIMITS_PREFIXES = (
    "onboarding/", ".github/", "scripts/", "figma-ai-fix/", "migration_sim_test/",
    "lib/src/rust/",
)
OFF_LIMITS_FILES = {"CLAUDE.md", "pubspec.yaml", "pubspec.lock"}
OFF_LIMITS_SUBSTR = ("frb_generated",)
OFF_LIMITS_SUFFIX = (".g.dart", ".freezed.dart")

# Desktop-only (owner update: iOS + Android first, skip desktop).
DESKTOP_NATIVE_PREFIXES = ("windows/", "linux/", "macos/")
# Desktop-only Dart files that do not carry "desktop" in their name.  They are the
# desktop counterparts of screens under .../mobile/ and are routed only from
# _desktopRoutes / appDesktopOnboardingRoutes in lib/app.dart (verified by an import
# walk from every mobile file: none of them is reachable from mobile code).
DESKTOP_DART_FILES = {
    "lib/src/core/widgets/linux_keyring_gate.dart",
    "lib/src/features/about/screens/about_screen.dart",
    "lib/src/features/accounts/widgets/account_remove_modal.dart",
    "lib/src/features/donation/widgets/donation_views.dart",
    "lib/src/features/home/screens/home_screen.dart",
    "lib/src/features/home/widgets/keystone_shield_signing_overlay.dart",
    "lib/src/features/migration/widgets/ironwood_migration_privacy_lock_host.dart",
    "lib/src/features/onboarding/import/import_birthday_unknown_height_modal.dart",
    "lib/src/features/onboarding/keystone/keystone_how_to_connect_screen.dart",
    "lib/src/features/onboarding/lost_password_screen.dart",
    "lib/src/features/onboarding/unlock_screen.dart",
    "lib/src/features/send/screens/send_review_screen.dart",
    "lib/src/features/settings/screens/settings_screen.dart",
    "lib/src/features/settings/screens/settings_uninstall_screen.dart",
    "lib/src/features/settings/widgets/windows_update_download_flow.dart",
    "lib/src/providers/linux_update_provider.dart",
    "lib/widgetbook/donation_use_cases.dart",
}

# The portfolio-chart feature's own files: another agent rewrites that copy.
CHART_SKIP = (
    "lib/src/features/portfolio_chart/",
    "lib/src/features/settings/widgets/mobile/mobile_portfolio_chart_settings_card.dart",
    "lib/widgetbook/portfolio_chart_fixtures.dart",
    "test/features/portfolio_chart/",
    "test/features/settings/mobile_portfolio_chart_settings_test.dart",
)

# Dart literals that look like UI text but must keep the old word.
#   (path regex, decoded-text regex, reason)
DART_KEEP_LITERALS = [
    # Exception messages that no UI shows (every catch site ignores the message).
    (r"^lib/src/features/wallet_link/models/wallet_link_models\.dart$",
     r"Vizor wallet link", "FormatException message, never shown"),
    (r"^lib/src/features/payment_links/models/vizor_payment_link\.dart$",
     r"not a Vizor payment link", "FormatException message, never shown"),
    # Desktop-only Figma scenario for the desktop settings screen.
    (r"^lib/figma_compare/figma_compare_scenarios\.dart$",
     r"^Desktop settings scrolled to Support Vizor$", "desktop-only scenario text"),
]
# `appId: 'Vizor'` is the Windows/Velopack update-feed id, not UI text.
DART_KEEP_BEFORE = [r"appId:\s*$"]

# Test literals whose meaning is decided by hand after the automatic phrase match
# (path regex, decoded-text regex, "keep" | "change", reason).
TEST_OVERRIDES: list[tuple[str, str, str, str]] = [
    # (none for the mobile+shared pass.  The two desktop absence checks for the mobile
    # "Link Vizor Desktop" option are kept as-is for now; the --include-desktop pass
    # converts them with the rest of the desktop tests.)
]
# Untagged tests that exercise a desktop-only screen: a literal that also occurs in a
# changed (mobile/shared) source is still the desktop screen's text -> keep.
TEST_AMBIGUOUS_KEEP_FILES = {
    "test/app_desktop_onboarding_selection_test.dart",
    "test/app_main_sidebar_test.dart",
    "test/core/widgets/linux_keyring_gate_test.dart",
    "test/features/about/about_legal_pages_test.dart",
    "test/features/accounts/accounts_screen_test.dart",
    "test/features/donation/donation_views_test.dart",
    "test/features/migration/ironwood_migration_privacy_lock_host_test.dart",
    "test/features/onboarding/desktop_method_selection_screen_test.dart",
    "test/features/onboarding/keystone_how_to_connect_screen_test.dart",
    "test/features/onboarding/lost_password_screen_test.dart",
    "test/features/payment_links/gift_claim_desktop_test.dart",
    "test/features/send/send_review_screen_test.dart",
    "test/features/send/send_status_screen_test.dart",
    "test/features/settings/settings_screen_test.dart",
    "test/features/settings/settings_uninstall_screen_test.dart",
    "test/widgetbook/accounts_use_cases_test.dart",
    "test/widgetbook/receive_use_cases_test.dart",
    "test/widgetbook/settings_use_cases_test.dart",
}

# Test-description call sites: their first string argument is a test name.
TEST_DESC_CALL = re.compile(
    r"(?:^|[^A-Za-z0-9_$.])(?:test|testWidgets|group|testGoldens|testGolden|testOn|"
    r"testFlutter|tearDownAll|setUpAll)\s*\(\s*$"
)

# Markdown: files that get the prose transform.
MD_ROOT_FILES = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "AGENTS.md"]
MD_GLOBS = ["docs/*.md", "release_notes/*.md", "rust/src/*.md"]
MD_FENCE_FILES = {"release_notes/README.md"}  # its fenced blocks hold the changelog template

# Markdown prose lines that mention the word but must stay (path regex, line regex).
MD_KEEP_LINES: list[tuple[str, str]] = []

# Explicit text edits (file -> [(old, new)]).  `old` must be a quoted/visible string.
# Each pair is applied with str.replace and is idempotent (new != old, new contains
# nothing that matches old).
EXPLICIT_EDITS: dict[str, list[tuple[str, str]]] = {
    # --- Android -------------------------------------------------------------
    "android/app/src/main/AndroidManifest.xml": [
        ('android:label="Vizor"', 'android:label="Veylor"'),
    ],
    "fastlane/metadata/android/en-US/title.txt": [
        ("Vizor - Zcash Wallet", "Veylor - Zcash Wallet"),
    ],
    "fastlane/metadata/android/en-US/full_description.txt": [
        ("Vizor is a self-custody Zcash wallet", "Veylor is a self-custody Zcash wallet"),
        ("Vizor cannot recover it for you.", "Veylor cannot recover it for you."),
    ],
    # --- iOS ------------------------------------------------------------------
    "ios/Runner/Info.plist": [
        ("<string>Vizor uses the camera", "<string>Veylor uses the camera"),
        ("<string>Vizor uses Bluetooth", "<string>Veylor uses Bluetooth"),
        ("<string>Vizor uses Face ID", "<string>Veylor uses Face ID"),
        ("<key>CFBundleDisplayName</key>\n\t\t<string>Vizor</string>",
         "<key>CFBundleDisplayName</key>\n\t\t<string>Veylor</string>"),
        ("<key>CFBundleName</key>\n\t\t<string>Vizor</string>",
         "<key>CFBundleName</key>\n\t\t<string>Veylor</string>"),
    ],
    # --- Rust: error strings that reach the UI (rebuild + codegen check needed) ---
    "rust/src/api/wallet.rs": [
        ('"Vizor can\'t check this recovery phrase', '"Veylor can\'t check this recovery phrase'),
        ('"Vizor couldn\'t privately check this recovery phrase',
         '"Veylor couldn\'t privately check this recovery phrase'),
    ],
    "rust/src/wallet/sync/pczt.rs": [
        ("so Vizor can build a fresh transaction.", "so Veylor can build a fresh transaction."),
    ],
    "rust/src/wallet/sync/send.rs": [
        ("Vizor will reconcile it on the next advance.", "Veylor will reconcile it on the next advance."),
        ("Vizor will retry until local state is recorded.", "Veylor will retry until local state is recorded."),
        ("Vizor records a submitted transaction after the wallet syncs.",
         "Veylor records a submitted transaction after the wallet syncs."),
    ],
    "rust/src/wallet/sync/send/ironwood_migration.rs": [
        ('"Vizor is still finishing migration proofs. Try again shortly."',
         '"Veylor is still finishing migration proofs. Try again shortly."'),
        ('"Vizor proof generation failed. Reject and prepare a new request."',
         '"Veylor proof generation failed. Reject and prepare a new request."'),
    ],
    "rust/src/wallet/sync/send/tests.rs": [
        ('message.contains("Vizor will retry")', 'message.contains("Veylor will retry")'),
    ],
    # --- exported file names people see in save dialogs / share sheets -----------
    "lib/src/features/payment_links/services/payment_link_batch_export.dart": [
        ("'vizor-gift-cards-$date.csv'", "'veylor-gift-cards-$date.csv'"),
    ],
    "lib/src/features/payment_links/services/payment_link_qr_export.dart": [
        ("fileName: 'vizor-gift-card.png'", "fileName: 'veylor-gift-card.png'"),
    ],
    "lib/src/features/payment_links/services/payment_link_qr_image_saver.dart": [
        ("_suggestedName = 'vizor-gift-card.png'", "_suggestedName = 'veylor-gift-card.png'"),
    ],
    "lib/src/features/receive/services/request_qr_export.dart": [
        ("const _requestQrFileStem = 'vizor-request';", "const _requestQrFileStem = 'veylor-request';"),
    ],
    "test/core/sharing/qr_png_share_test.dart": [
        ("expectedName = 'vizor-gift-card.png'", "expectedName = 'veylor-gift-card.png'"),
    ],
    "test/features/receive/receive_screen_test.dart": [
        ("['vizor-request-0.5.png']", "['veylor-request-0.5.png']"),
    ],
    "test/features/receive/zec_request_draft_test.dart": [
        ("'vizor-request-0.5.png'", "'veylor-request-0.5.png'"),
        ("'vizor-request.png'", "'veylor-request.png'"),
        ("'vizor-request-1.png'", "'veylor-request-1.png'"),
        ("['vizor-request-0.5.png']", "['veylor-request-0.5.png']"),
    ],
    # --- docs: the exported CSV name quoted in a code span ----------------------
    "docs/gift-card-groups.md": [
        ("`vizor-gift-cards-YYYY-MM-DD.csv`", "`veylor-gift-cards-YYYY-MM-DD.csv`"),
    ],
    # --- dev demo page ---------------------------------------------------------
    "dev/payment_uri_demo.html": [
        ("<title>Vizor Payment URI Demo</title>", "<title>Veylor Payment URI Demo</title>"),
        ("Open in Vizor", "Open in Veylor"),
    ],
}

# Desktop native user-visible strings (only with --include-desktop).  Packaging
# internals (PRODUCT_NAME, Vizor.app, .exe names, Velopack/Sparkle ids and feeds,
# Windows resource strings, window class names) are deliberately NOT listed.
DESKTOP_EXPLICIT_EDITS: dict[str, list[tuple[str, str]]] = {
    "linux/CMakeLists.txt": [('set(APP_DISPLAY_NAME "Vizor")', 'set(APP_DISPLAY_NAME "Veylor")')],
    "macos/Runner/Info.plist": [
        ("<string>Vizor uses the camera", "<string>Veylor uses the camera"),
        ("<string>Vizor uses Bluetooth", "<string>Veylor uses Bluetooth"),
    ],
}

# C-like source files with user-visible strings (string-literal-only transform).
CLIKE_ROOTS_MOBILE = ("ios/Runner/", "ios/SyncWidget/", "ios/RunnerTests/", "android/app/src/")
CLIKE_ROOTS_DESKTOP = ("macos/Runner/", "windows/runner/", "linux/runner/")
CLIKE_SUFFIX = (".swift", ".kt", ".cpp", ".cc", ".h")
# Desktop C-like files: only these lines' strings are user-visible UI.
CLIKE_DESKTOP_ONLY_FILES = {
    "macos/Runner/AppDelegate.swift", "macos/Runner/MainFlutterWindow.swift",
    "windows/runner/main.cpp", "windows/runner/flutter_window.cpp",
}
# String literals in C-like files that must keep the word.
CLIKE_KEEP = [
    r"Vizor Update/",          # Windows updater user agent
    r"\[Vizor uninstall\]",    # debug log line
    r"Vizor update:",          # diagnostic log line
]

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def run_git_ls(root: Path) -> list[str]:
    out = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"])
    return [p for p in out.decode("utf-8").split("\0") if p]


def is_off_limits(p: str) -> bool:
    return (p in OFF_LIMITS_FILES or p.startswith(OFF_LIMITS_PREFIXES)
            or any(s in p for s in OFF_LIMITS_SUBSTR) or p.endswith(OFF_LIMITS_SUFFIX))


def is_chart(p: str) -> bool:
    return any(p == c or p.startswith(c) for c in CHART_SKIP)


def is_desktop_native(p: str) -> bool:
    return p.startswith(DESKTOP_NATIVE_PREFIXES)


def is_desktop_dart(p: str) -> bool:
    base = os.path.basename(p)
    return ("desktop" in base) or ("/desktop/" in p) or (p in DESKTOP_DART_FILES)


def read_text(path: Path) -> str | None:
    try:
        return path.read_bytes().decode("utf-8")
    except (UnicodeDecodeError, FileNotFoundError):
        return None


def line_of(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


# --- word-level context rule shared by every transform ------------------------

def brand_ok(s: str, i: int, j: int, *, allow_escape_before: bool = False) -> bool:
    """True when s[i:j] (the word) is a standalone brand mention, not part of a
    path, URL, host, file name, identifier or compound token."""
    prev = s[i - 1] if i > 0 else ""
    nxt = s[j] if j < len(s) else ""
    nn = s[j + 1] if j + 1 < len(s) else ""
    if prev and (prev.isalnum() or prev == "_"):
        if allow_escape_before:
            pre = s[max(0, i - 7):i]
            if re.search(r"(?<!\\)\\[nrt]$", pre) or re.search(r"(?<!\\)\\u[0-9a-fA-F]{4}$", pre):
                prev = ""
            else:
                return False
        else:
            return False
    if nxt and (nxt.isalnum() or nxt == "_"):
        return False
    if prev and prev in "/\\.@:=$%#~-":
        return False
    if nxt == "\\":
        # an escape right after the word (\' \" \n ’) is fine; a path separator is not
        if nn not in "'\"nrt$u":
            return False
    elif nxt in ("/", "@"):
        return False
    elif nxt == "." and nn and (nn.isalnum() or nn == "_"):
        return False
    elif nxt == "-" and nn and nn.isalnum():
        return False
    elif nxt == "+" and nn and nn.isdigit():
        return False
    elif nxt == ":" and s[j + 1:j + 3] == "//":
        return False
    return True


WORD_RE = re.compile(r"Vizor|VIZOR")
WORD_RE_LOW = re.compile(r"Vizor|VIZOR|vizor")


def swap_word(w: str) -> str:
    return {OLD: NEW, OLD_UP: NEW_UP, OLD_LOW: NEW_LOW}[w]


# ----------------------------------------------------------------------------
# change bookkeeping
# ----------------------------------------------------------------------------

@dataclass
class Stats:
    changed_files: dict = field(default_factory=lambda: collections.defaultdict(int))  # path -> occurrences
    changes: list = field(default_factory=list)       # (category, path, line, old, new)
    skipped_desktop: dict = field(default_factory=lambda: collections.defaultdict(int))
    skipped_chart: dict = field(default_factory=lambda: collections.defaultdict(int))
    kept_literals: list = field(default_factory=list)  # (path, line, text, reason)
    ambiguous: list = field(default_factory=list)
    warnings: list = field(default_factory=list)

    def record(self, cat, path, line, old, new):
        self.changed_files[(cat, path)] += 1
        self.changes.append((cat, path, line, old, new))


# ----------------------------------------------------------------------------
# Dart scanner
# ----------------------------------------------------------------------------

@dataclass
class Lit:
    start: int
    end: int
    spans: list          # [(a, b)] static text ranges in the source
    raw: bool
    depth: int           # 0 = top level, >0 = inside an interpolation


def scan_dart(src: str) -> list[Lit]:
    n = len(src)
    lits: list[Lit] = []

    def skip_block(i):
        depth = 0
        while i < n:
            if src.startswith("/*", i):
                depth += 1; i += 2
            elif src.startswith("*/", i):
                depth -= 1; i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def parse_string(i, depth):
        start = i
        raw = False
        if src[i] == "r":
            raw = True; i += 1
        q = src[i]
        ql = 3 if src.startswith(q * 3, i) else 1
        i += ql
        closing = q * ql
        spans = []
        seg = i
        while i < n:
            c = src[i]
            if not raw and c == "\\":
                i += 2
                continue
            if src.startswith(closing, i):
                spans.append((seg, i))
                i += ql
                lits.append(Lit(start, i, spans, raw, depth))
                return i
            if not raw and c == "$":
                if i + 1 < n and src[i + 1] == "{":
                    spans.append((seg, i))
                    i = scan_code(i + 2, True, depth + 1)
                    seg = i
                    continue
                m = IDENT.match(src, i + 1)
                if m:
                    spans.append((seg, i))
                    i = m.end()
                    seg = i
                    continue
            i += 1
        spans.append((seg, n))
        lits.append(Lit(start, n, spans, raw, depth))
        return n

    def scan_code(i, in_interp, depth):
        d = 1 if in_interp else 0
        while i < n:
            c = src[i]
            if c == "/" and i + 1 < n and src[i + 1] == "/":
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "/" and i + 1 < n and src[i + 1] == "*":
                i = skip_block(i)
                continue
            if c in "'\"":
                i = parse_string(i, depth)
                continue
            if (c == "r" and i + 1 < n and src[i + 1] in "'\""
                    and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$"))):
                i = parse_string(i, depth)
                continue
            if in_interp:
                if c == "{":
                    d += 1
                elif c == "}":
                    d -= 1
                    if d == 0:
                        return i + 1
            i += 1
        return i

    scan_code(0, False, 0)
    lits.sort(key=lambda L: L.start)
    return lits


_ESC = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v",
        "\\": "\\", "'": "'", '"': '"', "$": "$"}


def decode_dart(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            d = text[i + 1]
            if d == "u":
                m = re.match(r"u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})", text[i + 1:])
                if m:
                    out.append(chr(int(m.group(1) or m.group(2), 16)))
                    i += 1 + m.end()
                    continue
            if d == "x":
                m = re.match(r"x([0-9a-fA-F]{2})", text[i + 1:])
                if m:
                    out.append(chr(int(m.group(1), 16)))
                    i += 1 + m.end()
                    continue
            out.append(_ESC.get(d, d))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.replace("’", "'").replace("‘", "'")).strip()


def expressions(src: str, lits: list[Lit]):
    """Adjacent top-level literals form one string expression.  Returns a list of
    (lits_in_expression, [decoded fragments between interpolations])."""
    tops = [L for L in lits if L.depth == 0]
    groups, cur = [], []
    for L in tops:
        if cur and src[cur[-1].end:L.start].strip() == "":
            cur.append(L)
        else:
            if cur:
                groups.append(cur)
            cur = [L]
    if cur:
        groups.append(cur)
    result = []
    for g in groups:
        frags, acc = [], ""
        for L in g:
            for k, (a, b) in enumerate(L.spans):
                acc += decode_dart(src[a:b]) if not L.raw else src[a:b]
                if k < len(L.spans) - 1:
                    frags.append(acc); acc = ""
        frags.append(acc)
        result.append((g, frags))
    return result


# ----------------------------------------------------------------------------
# Dart processing
# ----------------------------------------------------------------------------

def dart_candidate_edits(path: str, src: str):
    """Yield (a, b, new_text, literal_info) for each brand occurrence inside a Dart
    string literal that passes the word-level context rule."""
    lits = scan_dart(src)
    for L in lits:
        for (a, b) in L.spans:
            for m in WORD_RE.finditer(src, a, b):
                if brand_ok(src, m.start(), m.end(), allow_escape_before=True):
                    yield m.start(), m.end(), swap_word(m.group(0)), L


def expr_index(src: str, lits: list[Lit]):
    """map literal start -> (expression first literal, frags)"""
    idx = {}
    for g, frags in expressions(src, lits):
        for L in g:
            idx[L.start] = (g, frags)
    return idx


def collect_fragments(root: Path, paths: list[str]) -> list[str]:
    out = []
    for p in paths:
        src = read_text(root / p)
        if src is None or not WORD_RE.search(src):
            continue
        lits = scan_dart(src)
        for g, frags in expressions(src, lits):
            for f in frags:
                if WORD_RE.search(f):
                    nf = norm(f)
                    if len(nf) >= 8:
                        out.append(nf)
    return out


def related(text_frags: list[str], source_frags: list[str]) -> bool:
    for t in text_frags:
        nt = norm(t)
        if len(nt) < 8:
            continue
        for s in source_frags:
            if nt in s or s in nt:
                return True
    return False


def process_dart(root: Path, files: list[str], opts, stats: Stats):
    lib_files = [p for p in files if p.startswith("lib/") and p.endswith(".dart")
                 and not is_off_limits(p)]
    test_files = [p for p in files if (p.startswith("test/") or p.startswith("integration_test/"))
                  and p.endswith(".dart") and not is_off_limits(p)]

    # Pass 1: classify lib sources and collect the fragments of changed vs skipped ones.
    changed_src, skipped_src = [], []
    for p in lib_files:
        if is_chart(p):
            continue
        (skipped_src if (is_desktop_dart(p) and not opts.include_desktop) else changed_src).append(p)
    changed_frags = collect_fragments(root, changed_src)
    skipped_frags = [] if opts.include_desktop else collect_fragments(root, skipped_src)

    for p in lib_files + test_files:
        full = root / p
        src = read_text(full)
        if src is None:
            continue
        if not WORD_RE.search(src):
            continue
        is_test = not p.startswith("lib/")
        lits = scan_dart(src)
        eidx = expr_index(src, lits)
        edits = []   # (a, b, new)
        for a, b, new, L in dart_candidate_edits(p, src):
            line = line_of(src, a)
            text_here = decode_dart("".join(src[x:y] for x, y in L.spans))   # inner text, no quotes
            # --- scope skips -------------------------------------------------
            if is_chart(p):
                stats.skipped_chart[p] += 1
                continue
            if (not is_test) and is_desktop_dart(p) and not opts.include_desktop:
                stats.skipped_desktop[("dart-lib", p)] += 1
                continue
            # --- per-literal keeps -------------------------------------------
            before = src[max(0, L.start - 60):L.start]
            if any(re.search(rx, before) for rx in DART_KEEP_BEFORE):
                stats.kept_literals.append((p, line, norm(text_here)[:90], "update-feed app id"))
                continue
            keep = False
            for prx, trx, why in DART_KEEP_LITERALS:
                if re.search(prx, p) and re.search(trx, text_here):
                    stats.kept_literals.append((p, line, norm(text_here)[:90], why))
                    keep = True
                    break
            if keep:
                continue
            g, frags = eidx.get(L.start, ([L], [text_here]))
            if is_test:
                # test descriptions stay
                head = g[0]
                if TEST_DESC_CALL.search(src[max(0, head.start - 80):head.start]):
                    stats.kept_literals.append((p, line, norm(text_here)[:90], "test description"))
                    continue
                if re.search(r"(?:fail\(|reason:\s*)$", src[max(0, head.start - 30):head.start]):
                    stats.kept_literals.append((p, line, norm(text_here)[:90], "test failure message"))
                    continue
                decision = None
                for prx, trx, act, why in TEST_OVERRIDES:
                    if re.search(prx, p) and re.search(trx, text_here):
                        decision = (act, why)
                        break
                mobile_tagged = bool(re.search(r"^@Tags\(\[[^\]]*'mobile'", src, re.M))
                rel_s = related(frags, skipped_frags)
                rel_c = related(frags, changed_frags)
                if decision is None:
                    if mobile_tagged:
                        decision = ("change", "mobile lane")
                    elif rel_s and not rel_c:
                        decision = ("keep", "asserts a desktop-only string")
                    elif rel_s and rel_c:
                        stats.ambiguous.append((p, line, norm(text_here)[:100]))
                        if p in TEST_AMBIGUOUS_KEEP_FILES:
                            decision = ("keep", "desktop-only screen test")
                        else:
                            decision = ("change", "ambiguous: also in a desktop-only source")
                    else:
                        decision = ("change", "shared/fixture")
                if decision[0] == "keep":
                    stats.skipped_desktop[("dart-test", p)] += 1
                    continue
            edits.append((a, b, new, line, norm(text_here)[:90]))
        if not edits:
            continue
        new_src = src
        for a, b, new, line, shown in sorted(edits, key=lambda e: -e[0]):
            new_src = new_src[:a] + new + new_src[b:]
        for a, b, new, line, shown in edits:
            stats.record("dart-test" if is_test else "dart-lib", p, line, shown, "")
        if not opts.dry_run:
            full.write_text(new_src, encoding="utf-8")


# ----------------------------------------------------------------------------
# C-like (Swift / Kotlin / C++) string-literal transform
# ----------------------------------------------------------------------------

def clike_line_edits(line: str, state: dict):
    """Yield (a, b, new) for brand words inside "..." literals of one line.  Tracks
    block comments across lines via state['block']."""
    i, n = 0, len(line)
    in_str = False
    while i < n:
        c = line[i]
        if state.get("block"):
            j = line.find("*/", i)
            if j < 0:
                return
            state["block"] = False
            i = j + 2
            continue
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
                i += 1
                continue
            m = WORD_RE.match(line, i)
            if m and brand_ok(line, m.start(), m.end(), allow_escape_before=True):
                yield m.start(), m.end(), swap_word(m.group(0))
                i = m.end()
                continue
            i += 1
            continue
        if line.startswith("//", i):
            return
        if line.startswith("/*", i):
            state["block"] = True
            i += 2
            continue
        if c == '"':
            in_str = True
        i += 1


def clike_file_edits(src: str):
    """[(line_no, line, [(a, b, new)])] for the user-visible brand words of a C-like file."""
    result, state = [], {}
    for ln, line in enumerate(src.split("\n"), 1):
        edits = list(clike_line_edits(line, state))
        if edits and any(re.search(k, line) for k in CLIKE_KEEP):
            edits = []
        if edits:
            result.append((ln, line, edits))
    return result


def process_clike(root: Path, files: list[str], opts, stats: Stats):
    for p in files:
        if not p.endswith(CLIKE_SUFFIX) or is_off_limits(p):
            continue
        desktop = is_desktop_native(p)
        if desktop:
            if p not in CLIKE_DESKTOP_ONLY_FILES:
                continue
        elif not p.startswith(CLIKE_ROOTS_MOBILE):
            continue
        src = read_text(root / p)
        if src is None or not WORD_RE.search(src):
            continue
        found = clike_file_edits(src)
        if not found:
            continue
        if desktop and not opts.include_desktop:
            stats.skipped_desktop[("native", p)] += sum(len(e) for _, _, e in found)
            continue
        lines = src.split("\n")
        for ln, line, edits in found:
            new_line = line
            for a, b, new in sorted(edits, key=lambda e: -e[0]):
                new_line = new_line[:a] + new + new_line[b:]
            lines[ln - 1] = new_line
            for _ in edits:
                stats.record("native-desktop" if desktop else "native-mobile", p, ln, line.strip()[:110], "")
        if not opts.dry_run:
            (root / p).write_text("\n".join(lines), encoding="utf-8")


# ----------------------------------------------------------------------------
# explicit edits (manifest, plists, store listing, Rust, ...)
# ----------------------------------------------------------------------------

def process_explicit(root: Path, table: dict, cat: str, opts, stats: Stats):
    for p, pairs in table.items():
        full = root / p
        src = read_text(full)
        if src is None:
            stats.warnings.append(f"explicit edit target missing: {p}")
            continue
        new_src = src
        for old, new in pairs:
            if old in new_src:
                cnt = new_src.count(old)
                new_src = new_src.replace(old, new)
                for _ in range(cnt):
                    stats.record(cat, p, 0, old[:90], new[:90])
            elif new not in new_src:
                stats.warnings.append(f"{p}: neither old nor new text found for {old[:60]!r}")
        if new_src != src and not opts.dry_run:
            full.write_text(new_src, encoding="utf-8")


# ----------------------------------------------------------------------------
# Markdown prose transform
# ----------------------------------------------------------------------------

_MASK_RE = re.compile(
    r"\]\([^)\n]*\)"              # link / image destinations
    r"|<https?://[^>\s]+>"        # autolinks
    r"|https?://[^\s<>)\]]+"      # bare URLs
    r"|<[A-Za-z/][^>\n]*>"        # html tags (attribute values stay untouched)
    r"|\]\:\s*\S+"                # reference definitions
)
UI_SENTENCE = re.compile(r"^[^/\\=_<>{}\[\]|]*$")


MD_PROSE_COMPOUND = re.compile(r"-(?:operated|owned|managed|hosted|run|specific)(?![A-Za-z0-9_.\-])")


def md_prose(seg: str, lower_ok: bool) -> tuple[str, int]:
    masked = _MASK_RE.sub(lambda m: "\x00" * len(m.group(0)), seg)
    rx = WORD_RE_LOW if lower_ok else WORD_RE
    out, last, n = [], 0, 0
    for m in rx.finditer(masked):
        if not brand_ok(masked, m.start(), m.end()):
            # "Vizor-operated proxy": a prose compound, not a file or artifact name
            if not (masked[m.end():m.end() + 1] == "-" and MD_PROSE_COMPOUND.match(masked, m.end())
                    and brand_ok(masked[:m.end()] + " ", m.start(), m.end())):
                continue
        out.append(seg[last:m.start()])
        out.append(swap_word(m.group(0)))
        last = m.end()
        n += 1
    out.append(seg[last:])
    return "".join(out), n


def md_codespan(content: str) -> tuple[str, int]:
    st = content.strip()
    if st in (OLD, OLD_UP):                                  # the bare word, e.g. the proper-noun list
        return content.replace(st, swap_word(st)), 1
    words = st.split()
    if (len(words) >= 4 and st[-1] in ".!?" and re.search(r"(?<![A-Za-z0-9_])Vizor(?![A-Za-z0-9_])", st)
            and UI_SENTENCE.match(st)):                      # a quoted UI sentence
        return md_prose(content, False)
    return content, 0


def md_line(line: str, lower_ok: bool) -> tuple[str, int]:
    """Prose is transformed, code spans only by md_codespan."""
    runs = [(m.start(), m.end()) for m in re.finditer(r"`+", line)]
    spans, k = [], 0
    while k < len(runs):
        s0, e0 = runs[k]
        width = e0 - s0
        found = next((q for q in range(k + 1, len(runs)) if runs[q][1] - runs[q][0] == width), None)
        if found is None:
            k += 1
            continue
        spans.append((s0, e0, runs[found][0], runs[found][1]))
        k = found + 1
    out, pos, total = [], 0, 0
    for (s0, e0, s1, e1) in spans:
        seg, c = md_prose(line[pos:s0], lower_ok)
        out.append(seg); total += c
        inner, c2 = md_codespan(line[e0:s1])
        out.append(line[s0:e0] + inner + line[s1:e1]); total += c2
        pos = e1
    seg, c = md_prose(line[pos:], lower_ok)
    out.append(seg); total += c
    return "".join(out), total


def md_transform(text: str, relpath: str):
    process_fences = relpath in MD_FENCE_FILES
    lower_ok = True     # lowercase "vizor" is only replaced where it stands alone in prose
    out, in_fence, fence = [], False, ""
    changes = []
    for ln, line in enumerate(text.splitlines(keepends=True), 1):
        stripped = line.lstrip()
        m = re.match(r"(`{3,}|~{3,})", stripped)
        if m:
            if not in_fence:
                in_fence, fence = True, m.group(1)
            elif m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                in_fence = False
            out.append(line)
            continue
        if any(re.search(rx, line) for pr, rx in MD_KEEP_LINES if re.search(pr, relpath)):
            out.append(line)
            continue
        if in_fence and not process_fences:
            out.append(line)
            continue
        if in_fence:
            new, c = md_prose(line, lower_ok)
        else:
            new, c = md_line(line, lower_ok)
        if c:
            changes.append((ln, line.strip()[:110]))
        out.append(new)
    return "".join(out), changes


def process_markdown(root: Path, files: list[str], opts, stats: Stats):
    targets = [p for p in files if p in MD_ROOT_FILES
               or any(fnmatch.fnmatch(p, g) for g in MD_GLOBS)]
    for p in targets:
        if is_off_limits(p) or is_chart(p):
            continue
        full = root / p
        src = read_text(full)
        if src is None:
            continue
        new_src, changes = md_transform(src, p)
        for ln, shown in changes:
            stats.record("docs", p, ln, shown, "")
        if new_src != src and not opts.dry_run:
            full.write_text(new_src, encoding="utf-8")


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repository (or worktree) root")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--include-desktop", action="store_true")
    ap.add_argument("--only", default="dart,native,rust,docs,store",
                    help="comma list: dart, native (ios/android), rust, docs, store")
    ap.add_argument("--report", default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    opts = ap.parse_args()
    root = Path(opts.root).resolve()
    only = set(opts.only.split(","))
    files = run_git_ls(root)
    stats = Stats()

    if "dart" in only:
        process_dart(root, files, opts, stats)
        process_explicit(root, {k: v for k, v in EXPLICIT_EDITS.items()
                                if k.startswith(("lib/", "test/", "integration_test/"))},
                         "dart-filenames", opts, stats)
    if "native" in only:
        process_clike(root, files, opts, stats)
        process_explicit(root, {k: v for k, v in EXPLICIT_EDITS.items()
                                if k.startswith(("android/", "ios/"))}, "native-mobile", opts, stats)
        if opts.include_desktop:
            process_explicit(root, DESKTOP_EXPLICIT_EDITS, "native-desktop", opts, stats)
        else:
            # count (do not change) the desktop native user-visible strings
            for p, pairs in DESKTOP_EXPLICIT_EDITS.items():
                src = read_text(root / p) or ""
                n = sum(src.count(o) for o, _ in pairs)
                if n:
                    stats.skipped_desktop[("native", p)] += n
    if "store" in only:
        process_explicit(root, {k: v for k, v in EXPLICIT_EDITS.items() if k.startswith("fastlane/metadata/")},
                         "store-listing", opts, stats)
    if "rust" in only:
        process_explicit(root, {k: v for k, v in EXPLICIT_EDITS.items() if k.startswith("rust/")},
                         "rust", opts, stats)
    if "docs" in only:
        process_markdown(root, files, opts, stats)
        process_explicit(root, {k: v for k, v in EXPLICIT_EDITS.items() if k.startswith(("docs/", "dev/"))},
                         "docs", opts, stats)

    # ---- summary -----------------------------------------------------------
    by_cat = collections.Counter()
    files_by_cat = collections.defaultdict(set)
    for cat, p, *_ in stats.changes:
        by_cat[cat] += 1
        files_by_cat[cat].add(p)
    print("== %s ==" % ("DRY RUN" if opts.dry_run else "APPLIED"))
    for cat in sorted(by_cat):
        print(f"{cat:16s} {by_cat[cat]:5d} occurrences in {len(files_by_cat[cat]):3d} files")
    kinds = collections.defaultdict(lambda: [0, set()])
    for (kind, path), n in stats.skipped_desktop.items():
        kinds[kind][0] += n
        kinds[kind][1].add(path)
    for kind in sorted(kinds):
        print(f"skipped desktop-only [{kind}]: {kinds[kind][0]} occurrences in {len(kinds[kind][1])} files")
    sc = sum(stats.skipped_chart.values())
    print(f"skipped (chart feature): {sc} occurrences in {len(stats.skipped_chart)} files")
    print(f"kept literals (functional/description): {len(stats.kept_literals)}")
    print(f"ambiguous test literals changed: {len(stats.ambiguous)}")
    for w in stats.warnings:
        print("WARNING:", w)
    if opts.report:
        Path(opts.report).write_text(json.dumps({
            "changes": stats.changes,
            "skipped_desktop": [[k[0], k[1], v] for k, v in stats.skipped_desktop.items()],
            "skipped_chart": stats.skipped_chart,
            "kept_literals": stats.kept_literals,
            "ambiguous": stats.ambiguous,
            "warnings": stats.warnings,
        }, indent=1, ensure_ascii=False))
    if opts.verbose:
        for cat, p, ln, old, new in stats.changes:
            print(f"  [{cat}] {p}:{ln}: {old}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
