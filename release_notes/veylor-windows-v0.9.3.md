# Veylor Wallet v0.9.3 for Windows (beta)

The first public release of Veylor for Windows, in beta. Veylor is a private
Zcash wallet, a fork of Vizor, with a new neon look and Shielded USD: a
private dollar balance you can bridge to and from shielded ZEC. Every file is
built and published by GitHub Actions from the release's commit, with a signed
record of that build.

## What's New

- Shielded USD: hold USDC privately on Railgun, beside your shielded ZEC.
- Bridge shielded ZEC to Shielded USD and back. Before you confirm, a bridge
  shows its fees, including any fee the market maker asks to open it, which
  isn't refunded. Veylor pays that fee only once your wallet has finished
  syncing. If a bridge can't complete, Veylor refunds it.
- Send Shielded USD to a 0zk address, or withdraw it to an Ethereum address.
- Receive Shielded USD at your 0zk address, or receive USDC on Ethereum at
  your deposit address. Veylor shields deposits while it's open and unlocked.
- Shielded USD payments and bridges appear in Home's recent activity and in
  Activity.
- A new look: true black and neon red, with your balance as a lit sign and
  sync progress as a line of light.

## Which file to download

- `Veylor-windows-x64-Setup.exe` is for most PCs.
- `Veylor-windows-arm64-Setup.exe` is for ARM laptops, such as those with a
  Snapdragon processor.

## Check your download

- Compare the file's SHA-256 with its line in `SHA256SUMS`, all 64
  characters. In PowerShell: `Get-FileHash .\Veylor-windows-x64-Setup.exe`
  (Windows shows it in capitals, which doesn't matter). If they differ, don't
  open the file.
- Check where it was built, with GitHub's CLI:
  `gh attestation verify Veylor-windows-x64-Setup.exe --repo ChinmayGopal931/vizor-fork --signer-workflow ChinmayGopal931/vizor-fork/.github/workflows/veylor-windows.yml`.
  It confirms the file was built by this repository's Windows workflow, and
  shows the commit it was built from: the one this release is tagged at.

## Installing

- The installer isn't signed yet, so Windows shows "Windows protected your
  PC". Click **More info**, then **Run anyway**. If your browser warns that
  the file isn't commonly downloaded, keep it, and check it as above.
- Veylor installs for your Windows account, without administrator rights,
  with shortcuts on the Start menu and the desktop.

## Notes

- This is a beta. Start with small amounts.
- Veylor on Windows doesn't update itself yet: download new versions from
  veylor.cash.
- Shielded USD runs in Microsoft's WebView2, which Windows 11 includes. On
  Windows 10 you may need to install the WebView2 Runtime from Microsoft;
  without it, Veylor runs without Shielded USD.
- Shielded USD isn't available for Ledger or Keystone accounts.
- Keep Veylor open, unlocked and in view while a bridge needs it: if it's
  minimised, or your computer locks or sleeps, the bridge pauses until you're
  back. The bridge tells you when you can leave: with "Let the relayer claim
  for me" on, the default, you can leave a bridge to Shielded USD once the
  market maker confirms your deposit.
- Shielded USD uses a public Ethereum RPC. To use your own, set it in
  Settings under Ethereum RPC.
- Shielded USD's first sync can take a while. "Sync history from Anon's
  archive" in Settings, on by default, can shorten it.
- Uninstalling Veylor deletes its wallets from this computer, with their keys.
  Make sure you have each wallet's recovery phrase before you uninstall.
- Veylor keeps its own wallet data, apart from Vizor's, so an installed Vizor
  is unaffected. To use an existing wallet in Veylor, restore it from its
  recovery phrase.
- Veylor runs on Zcash mainnet.
