# Veylor Wallet v1.0.6 for Android

Veylor for Android, on Google Play and as a direct download: the APK is built
by GitHub from Veylor's public code, so that anyone can build it again and get
the same file, and signed by Veylor. This release makes Shielded USD's sends
and bridges hold up better when an answer gets lost, and keeps more about your
phone private.

## Improvements

- Shielded USD no longer tells the servers it talks to your phone's language.
- Veylor's files stay out of Android's phone-to-phone transfer. Your wallet
  never moved that way: on a new phone, restore it from your recovery phrase.

## Fixes

- Scanning a desktop's wallet link now works.
- A Shielded USD send whose answer was lost is no longer shown as "not sent"
  while it could still go through. Veylor keeps it until Ethereum shows what
  happened, and your next payment waits for it.
- A bridge whose answer from the market maker was lost no longer ends early:
  Veylor waits for Ethereum to show what happened.
- A bridge's refund or payout no longer gets stuck when network fees rise.
- If your phone's clock is off, Shielded USD says so, instead of saying it
  can't reach Ethereum.
- When your Ethereum RPC is down as Shielded USD starts, Veylor offers to try
  another. An Infura or Alchemy RPC is no longer turned away as not answering.
- Shielded USD recovers from a brief connection error instead of stopping, and a
  slow RPC no longer makes it rebuild its history every day.
- When Shielded USD's indexer can't be reached on a long catch-up, it says so
  instead of scanning for hours.
- After a week or more away, Shielded USD's catch-up keeps the screen on and
  gets the time it needs, as a first sync does.

## Which file to download

- **`veylor-1.0.6-14.apk`: install this one.** Veylor needs Android 11 or
  later.
- `veylor-1.0.6-14-unsigned.apk` is GitHub's build before signing, for
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
  veylor-1.0.6-14.apk` shows the SHA-256
  `83f16e2037b09e731e51b3472466db43c4a962ada1fb4e40eaa4c3215a2174f5`.
- GitHub built it from this release's commit: `gh attestation verify
  veylor-1.0.6-14-unsigned.apk --repo ChinmayGopal931/vizor-fork
  --signer-workflow ChinmayGopal931/vizor-fork/.github/workflows/veylor-android.yml`.
- Veylor's signature is the only difference: `apksigcopier compare
  veylor-1.0.6-14.apk --unsigned veylor-1.0.6-14-unsigned.apk`.
- Two builds on different machines produced the same bytes; to build it
  yourself, see "Android direct APK (verifiable)" in the repository's
  `docs/releases.md`.
