# Veylor Wallet v0.9.1 for Linux (beta)

Veylor for Linux, in beta: a private Zcash wallet, a fork of Vizor, with a new
neon look and Shielded USD, a private dollar balance you can bridge to and
from shielded ZEC. From this release on, every file is built and published by
GitHub Actions from the release's commit, with a signed record of that build,
so you can check that what you download comes from Veylor's public code.

## What's New

- Settings can copy Shielded USD's failure codes (Shielded USD, "Copy failure
  codes"): a short record of what failed, kept on your computer, to send us
  when something goes wrong. It holds no amounts, addresses, keys or messages.

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
  page. Install it with `sudo apt install ./veylor_0.9.1_amd64.deb` (or the
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
