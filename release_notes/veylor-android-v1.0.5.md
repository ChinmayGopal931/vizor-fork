# Veylor Wallet v1.0.5 for Android

Veylor for Android, on Google Play and as a direct download: the APK is built
by GitHub from Veylor's public code, so that anyone can build it again and get
the same file, and signed by Veylor.

## What's New

- Veylor pays a market maker's fee only once your wallet has finished
  syncing, so the bridge can always follow it.
- A bridge that paid a market maker's fee always says so, including when it
  was refunded or the fee confirmed after the bridge ended.
- An expired quote that asks a fee is replaced once, then waits for you to ask
  for another.

## Which file to download

- **`veylor-1.0.5-12.apk`: install this one.** Veylor needs Android 11 or
  later.
- `veylor-1.0.5-12-unsigned.apk` is GitHub's build before signing, for
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
  veylor-1.0.5-12.apk` shows the SHA-256
  `83f16e2037b09e731e51b3472466db43c4a962ada1fb4e40eaa4c3215a2174f5`.
- GitHub built it from this release's commit: `gh attestation verify
  veylor-1.0.5-12-unsigned.apk --repo ChinmayGopal931/vizor-fork
  --signer-workflow ChinmayGopal931/vizor-fork/.github/workflows/veylor-android.yml`.
- Veylor's signature is the only difference: `apksigcopier compare
  veylor-1.0.5-12.apk --unsigned veylor-1.0.5-12-unsigned.apk`.
- Two builds on different machines produced the same bytes; to build it
  yourself, see "Android direct APK (verifiable)" in the repository's
  AGENTS.md.
