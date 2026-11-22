# Veylor Wallet v1.0.4 for Android

Veylor for Android, on Google Play and as a direct download: the APK is built
by GitHub from Veylor's public code, so that anyone can build it again and get
the same file, and signed by Veylor.

## What's New

- Bridges from ZEC to Shielded USD can carry a small market maker fee, shown
  on the review before you bridge. Veylor pays it first, and the bridge opens
  once it confirms. The fee isn't refunded.
- If the market maker's answer to a bridge is lost on the way, Veylor follows
  the bridge from Ethereum instead of dropping it.
- A bridge's details show the network fee its deposit actually paid.

## Which file to download

- **`veylor-1.0.4-11.apk`: install this one.** Veylor needs Android 11 or
  later.
- `veylor-1.0.4-11-unsigned.apk` is GitHub's build before signing, for
  checking the APK. It doesn't install.

## Notes

- Veylor from Google Play is signed by Google, so Android won't update the one
  with the other. To switch, write down your recovery phrase, uninstall
  Veylor, install the other one and restore your wallet.
- The APK doesn't update itself: get new versions from
  https://veylor.cash/releases/.
- This APK leaves out Google Play's services: it never asks for a Play review.

## Check your download

- Its signing certificate must be Veylor's. `apksigner verify --print-certs
  veylor-1.0.4-11.apk` shows the SHA-256
  `83f16e2037b09e731e51b3472466db43c4a962ada1fb4e40eaa4c3215a2174f5`.
- GitHub built it from this release's commit: `gh attestation verify
  veylor-1.0.4-11-unsigned.apk --repo ChinmayGopal931/vizor-fork
  --signer-workflow ChinmayGopal931/vizor-fork/.github/workflows/veylor-android.yml`.
- Veylor's signature is the only difference: `apksigcopier compare
  veylor-1.0.4-11.apk --unsigned veylor-1.0.4-11-unsigned.apk`.
- Two builds on different machines produced the same bytes; to build it
  yourself, see "Android direct APK (verifiable)" in the repository's
  AGENTS.md.
