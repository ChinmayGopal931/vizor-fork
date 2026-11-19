# Veylor Wallet v0.9.0 (beta)

The first public release of Veylor for macOS, in beta. Veylor is a private
Zcash wallet, a fork of Vizor, with a new neon look and Shielded USD: a
private dollar balance you can bridge to and from shielded ZEC.

## What's New

- Shielded USD: hold USDC privately on Railgun, beside your shielded ZEC.
- Bridge shielded ZEC to Shielded USD and back. If a bridge can't complete,
  Veylor refunds it.
- Send Shielded USD to a 0zk address, or withdraw it to an Ethereum address.
- Receive Shielded USD at your 0zk address, or receive USDC on Ethereum at
  your deposit address. Veylor shields deposits while it's open and unlocked.
- Shielded USD payments and bridges appear in Home's recent activity and in
  Activity.
- A new look: true black and neon red, with your balance as a lit sign and
  sync progress as a line of light.
- Automatic updates. Veylor checks for new versions and installs them for
  you, and downloads them over Tor when Tor is on.

## Notes

- This is a beta. Start with small amounts.
- Veylor needs macOS 12 or later. Shielded USD needs macOS 14 or later; on
  macOS 12 and 13, Veylor runs without it.
- Shielded USD isn't available for Ledger or Keystone accounts.
- Keep Veylor open, unlocked and visible while a bridge needs it. The bridge
  tells you when you can leave: with "Let the relayer claim for me" on, the
  default, you can leave a bridge to Shielded USD once the market maker
  confirms your deposit.
- Shielded USD uses a public Ethereum RPC. To use your own, set it in
  Settings under Ethereum RPC.
- Shielded USD's first sync can take a while. "Sync history from Anon's
  archive" in Settings, on by default, can shorten it.
- Veylor keeps its own wallet data, apart from Vizor's, so an installed Vizor
  is unaffected. To use an existing wallet in Veylor, restore it from its
  recovery phrase. With both installed, macOS opens `zcash:` links in one of
  them.
- Veylor runs on Zcash mainnet.
