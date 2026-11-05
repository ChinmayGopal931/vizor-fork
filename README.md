![Veylor banner](.github/assets/gh-vizor-banner.png)

# Veylor

Veylor is a self-custody Zcash wallet for shielded ZEC, with a polished desktop
experience built around clarity, privacy, and ease of use. It is for users who
want to create, receive, shield, and send ZEC without giving a hosted wallet
service control over their funds.

Official public releases currently focus on signed and notarized macOS DMGs.

## Features

- Create or import a Zcash wallet.
- Use a clean, modern interface designed to make shielded Zcash easier to use.
- Receive to shielded Unified Addresses or transparent addresses.
- Send ZEC from shielded balance.
- Add memos when sending to shielded recipients.
- Shield funds received to a transparent address.
- Use multiple accounts in one wallet.
- Import Keystone hardware wallet accounts.
- Choose from preset or custom lightwalletd endpoints.
- View balances, sync progress, and transaction history in a focused desktop
  UI.
- Protect local access with an app password and privacy mode.

## Build From Source

Use the release tag that matches the DMG you want to verify:

```bash
git fetch --tags
git checkout release/vX.Y.Z
git rev-parse HEAD
```

Make sure the commit matches the GitHub release, then build:

```bash
fvm install
fvm flutter pub get
fvm flutter build macos --release \
  --dart-define=ZCASH_DEFAULT_NETWORK=main \
  --dart-define=VIZOR_COINGECKO_PRICE_BASE_URL=https://api.coingecko.com/api/v3
```

For testnet:

```bash
fvm flutter build macos --release \
  --dart-define=ZCASH_DEFAULT_NETWORK=test
```

`VIZOR_COINGECKO_PRICE_BASE_URL` controls the home screen ZEC price and 24h
change source. Open-source builds should use the public CoinGecko base URL
above; production builds can point this define at a Veylor-operated proxy,
which then has to serve `/simple/price`.

`VIZOR_PRICING_ENGINE_BASE_URL` controls the price history behind the mobile
Home portfolio chart: the origin of a pricing engine that serves
`GET /v1/prices` (daily ZEC prices in USD for a range of UTC dates). It
defaults to `https://zapp-pricing-engine.majorworker.workers.dev`. The app asks
it for nothing unless the user turns on "Use market prices" in Settings, and
then a request names only the coin, the currency, the resolution and the dates
(never anything from the wallet); the server sees the device's IP address
unless Tor is on. An empty, non-https or invalid value turns the chart's market
prices off.

The built app is at:

```text
build/macos/Build/Products/Release/Vizor.app
```

Local builds may not use the same Apple signing identity as the official
release. That is expected. The goal is to verify the source and behavior, not
to produce a byte-for-byte identical app.

## Package a Local DMG

```bash
mkdir -p dist/macos

scripts/package-macos-release-dmg.sh \
  --app-path build/macos/Build/Products/Release/Vizor.app \
  --output dist/macos/Vizor-local-macos.dmg
```

The DMG packaging script must run on macOS in a GUI session.

## Verify an Official DMG

Check the hash:

```bash
shasum -a 256 Vizor-macos.dmg
```

Then verify Apple signing and notarization:

```bash
DMG="Vizor-macos.dmg"

spctl --assess --type open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$DMG"

hdiutil attach "$DMG" -readonly
APP="/Volumes/Install Vizor Wallet/Vizor.app"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | egrep 'Identifier|TeamIdentifier|Authority'
spctl --assess --type execute -vv "$APP"
xcrun stapler validate "$APP"

hdiutil detach "/Volumes/Install Vizor Wallet"
```

Expected mainnet identity:

```text
Identifier=com.keplr.vizor
TeamIdentifier=SZTB68DXM4
Authority=Developer ID Application: Chainapsis Inc. (SZTB68DXM4)
```

For testnet, the app path and identifier are:

```text
/Volumes/Install Vizor Testnet Wallet/Vizor Testnet.app
Identifier=com.keplr.vizor.testnet
TeamIdentifier=SZTB68DXM4
```

## Anonymous RPC (ETHGlobal Mumbai, November 2026)

Veylor's Shielded USD feature reads Ethereum: the swap engine checks the
windows and Deposits contracts, and the Railgun page syncs its notes through an
Ethereum RPC. **Before the hackathon** those requests went straight to the RPC
provider (the build's keyed Alchemy or Infura URL, else publicnode), over Tor
only when the user had turned Tor on in Settings. The provider saw the phone's
IP address together with every deposit address, swap index and contract read.
Privacy was a setting, off by default.

**New during the hackathon:** every Ethereum JSON-RPC request goes through an
[anon-rpc](https://ethereum.github.io/anon-rpc/) worker by default, on
Android. Rust is the one gateway (`rust/src/anon_rpc.rs`): the engine's reads
go through it directly, and the Railgun page's providers point at a loopback
relay it serves, so neither has a direct path left. The worker is a bundle
whose keccak hash is pinned in a specifier contract on Ethereum; a second
hidden page runs the official browser harness, which checks the bundle against
that hash before running a byte of it in a null-origin sandbox. The default
network is tor-js (Arti compiled to WebAssembly, circuits built on the phone,
reaching Tor through a KPS gateway). The mode fails closed: while the page is
down or the worker is not ready, requests are refused, never sent directly.
Each account's reads carry their own isolation key, so two accounts' reads
leave through independent circuits. Settings has an "Anonymous RPC" row to pick
Tor, Nox (testnet) or Off.

Traffic that stays on its previous route, on purpose: the Zcash sync to
lightwalletd, the Railgun screening nodes, indexer and proving artifacts, the
swap maker, relayer and token issuer, the one-time check of an RPC URL the
user types in Settings, and the Home price. None of it is Ethereum JSON-RPC,
and all of it still follows the Tor switch. iOS keeps direct providers until
its host gains the page.

The plan, decisions and status are in `docs/anon-rpc-plan.md`. To build the
anon-rpc page: `cd android/anon-rpc-web && npm ci --ignore-scripts && npm run
build`. A build may name its own KPS gateways with
`--dart-define=VIZOR_ANON_RPC_TOR_GATEWAYS=ip:port:certhash,…`; without the
define it uses the Ethereum Foundation's demonstration gateway.

## CROPS

- **C.** What we run that the user depends on: nothing for the Zcash wallet
  (any lightwalletd), and for Shielded USD the swap maker and relayer, which
  bridging needs and sends use. If they disappear or refuse, balances, deposits
  and the on-chain refund paths of the windows contract remain; an open swap
  unwinds on chain. The KPS gateway for tor-js is the Ethereum Foundation's
  demonstration gateway unless a build names its own; if it goes away,
  Anonymous RPC fails closed and the user can switch to Nox or turn it off.
- **O.** Apache-2.0 (the Railgun page bundle ships GPL and AGPL code with its
  notices). A clean clone does not yet build on its own: `rust/Cargo.toml`
  patches the zecSwap crates to a checkout outside the repository until that
  revision is published; everything else, the anon-rpc page included, builds
  from the repo.
- **P.** The RPC provider sees Ethereum requests arriving from Tor exits (or
  mixnet exits), grouped by a per-account isolation key, never the phone's
  address. The KPS gateway sees the phone's address and encrypted Tor cells,
  never destinations or content. publicnode sees one public `eth_call` that
  reads the worker's hash. lightwalletd, the screening nodes, the indexer, the
  maker and the relayer see what they saw before, over Tor when Tor is on. The
  client has no analytics or trackers; Play builds carry Google's review SDK,
  which the degoogled build excludes.
- **S.** Seeds live in the platform's secure storage and never reach the
  anon-rpc page, whose worker runs in a null-origin sandbox with no access to
  keys, cookies or the app's storage. The worker's integrity rests on the hash
  in its specifier contract, whose owner (the network, published by the
  Ethereum Foundation and its adopters) can publish a new version; the
  gateway is a blind relay; Tor's own assumptions apply. Rust refuses to fall
  back to a direct connection.

## Notes

- Back up your mnemonic. Veylor cannot recover funds if you lose it.
- The local password protects this device only. It does not replace the
  mnemonic backup.
- Shielded transactions are scanned locally, but your lightwalletd endpoint can
  still see network metadata such as IP address and request timing.
- Transparent Zcash addresses and transactions are public on-chain.
- Some exchanges only support transparent withdrawals. Shield those funds after
  they arrive.
- Sending uses shielded balance. Transparent funds must be shielded first.
- Local rebuilds are not expected to match the official DMG byte-for-byte
  because Apple signing, notarization, timestamps, and DMG metadata differ.

## Development

```bash
fvm flutter run
fvm flutter test
fvm flutter analyze

cd rust && cargo test
```

Reviewing a quote calls the configured 1Click/proxy quote API and can return a
real one-time deposit instruction. Reviewing a quote does not move funds by
itself. Starting a ZEC-to-external swap sends the software-wallet deposit by
default; hardware-wallet accounts wait for Keystone signing.

After changing Rust API files in `rust/src/api/`, regenerate bindings from the
repo root:

```bash
flutter_rust_bridge_codegen generate
```

## Support Veylor

If Veylor is useful to you, consider supporting its continued development with
a ZEC donation.

<p align="center">
  <img src=".github/assets/zcash-donation-qr.png"
       alt="Zcash donation QR code"
       width="280">
</p>

**Zcash Unified Address**

```text
u15kdlm6j5tp4tptue4fdra4qa50d6zfl76anf7dagzu9y0yz875qhtvxgd6dju7l7epjwwxvuzh7z67gnxfw9msqxtnjg96x77x4y3vmzfehm0p9l6q2yhuskztxl8dlrswp6nf3u2j35krarnntc85h92h64g29f73ze5tewugq8tg3y
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
