# Veylor Wallet v0.9.4 for Linux (beta)

Veylor for Linux, in beta: a private Zcash wallet, a fork of Vizor, with a new
neon look and Shielded USD, a private dollar balance you can bridge to and
from shielded ZEC. Every file is built and published by GitHub Actions from
the release's commit, with a signed record of that build. This release makes
Shielded USD's sends and bridges hold up better when an answer gets lost.

## Improvements

- Shielded USD no longer tells the servers it talks to your computer's
  language.
- Shielded USD picks up again as soon as Veylor's window is back on screen,
  even before you click into it.

## Fixes

- A Shielded USD send whose answer was lost is no longer shown as "not sent"
  while it could still go through. Veylor keeps it until Ethereum shows what
  happened, and your next payment waits for it.
- A bridge whose answer from the market maker was lost no longer ends early:
  Veylor waits for Ethereum to show what happened.
- A bridge's refund or payout no longer gets stuck when network fees rise.
- A bridge already under way keeps going even when Shielded USD's page can't
  open. A sandbox check that timed out is tried again, instead of hiding
  Shielded USD until Veylor restarts.
- If your computer's clock is off, Shielded USD says so, instead of saying it
  can't reach Ethereum.
- When your Ethereum RPC is down as Shielded USD starts, Veylor offers to try
  another. An Infura or Alchemy RPC is no longer turned away as not answering.
- Shielded USD recovers from a brief connection error instead of stopping, and a
  slow RPC no longer makes it rebuild its history every day.
- When Shielded USD's indexer can't be reached on a long catch-up, it says so
  instead of scanning for hours.
- After a week or more away, Shielded USD's catch-up keeps the computer awake
  and gets the time it needs, as a first sync does.
- Shielded USD's page no longer waits forever for an old page to close, and a
  page that stops is no longer reported as a sandbox problem.

## Check your download

- Compare the file's SHA-256 with `SHA256SUMS`, all 64 characters:
  `sha256sum Veylor-linux-x86_64.AppImage`. If they differ, don't open the
  file.
- Check where it was built, with GitHub's CLI:
  `gh attestation verify Veylor-linux-x86_64.AppImage --repo ChinmayGopal931/vizor-fork`.
  It confirms the file was built by this repository's Linux workflow, and
  shows the commit it was built from: the one this release is tagged at.

## Which file to download

- **Ubuntu or Debian: the .deb.** It installs Veylor to `/opt/veylor`, with
  the permission Ubuntu 23.10 and later require for Shielded USD's protected
  page. Install it with `sudo apt install ./veylor_0.9.4_amd64.deb` (or the
  `arm64` file on an ARM computer).
- **Other distributions: the AppImage.** Make it executable and run it. On
  Ubuntu 23.10 and later, Shielded USD stays hidden in the AppImage, because
  Ubuntu only lets an installed app use the sandbox it needs: use the .deb
  there.
- `x86_64` and `amd64` are for most PCs; `aarch64` and `arm64` are for ARM
  computers.

## Notes

- This is a beta. Start with small amounts.
- Veylor needs a 64-bit system with glibc 2.35 or later, such as Ubuntu 22.04
  or Debian 12 and newer.
- Veylor keeps its secrets in your desktop's keyring (GNOME Keyring, or
  another Secret Service). If your system asks to unlock it, use your login
  password.
- Shielded USD needs WebKitGTK 4.1 (`libwebkit2gtk-4.1-0`), which Ubuntu's
  desktop already includes; the .deb recommends it. Without it, Veylor runs
  without Shielded USD.
- Shielded USD isn't available for Ledger or Keystone accounts.
- Keep Veylor open, unlocked and visible while a bridge needs it. The bridge
  tells you when you can leave: with "Let the relayer claim for me" on, the
  default, you can leave a bridge to Shielded USD once the market maker
  confirms your deposit.
- Shielded USD uses a public Ethereum RPC. To use your own, set it in
  Settings under Ethereum RPC.
- Shielded USD's first sync can take a while. "Sync history from Anon's
  archive" in Settings, on by default, can shorten it.
- Veylor on Linux doesn't update itself yet: download new versions from
  veylor.cash.
- Veylor keeps its own wallet data, apart from Vizor's, so an installed Vizor
  is unaffected. To use an existing wallet in Veylor, restore it from its
  recovery phrase.
- Veylor runs on Zcash mainnet.
