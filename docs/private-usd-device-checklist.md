# Private USD device checklist

The end-to-end runs for Private USD on Android (plan M8.5, §10). Run the
automated rounds on testnet and Sepolia for every release candidate, then
the manual runs, and the mainnet release QA last. M8 is done when this
checklist passes on mainnet with the beta limits.

Plan: `docs/private-usd-android-plan.md` (§3.5 invariants, §10 test
strategy, M8). Progress and deviations: `docs/private-usd-progress.md`.

## Before you start

- **Phone.** The Galaxy A35 (`RZCX40721QZ`) on USB, unlocked. Never an
  emulator.
- **No real wallet on the phone.** The runner refuses an installed
  `com.keplr.vizor` that is not debuggable, because it may be a real wallet.
  It never uninstalls anything.
- **Screen.** The runner sets `svc power stayon usb` and restores the
  original setting on exit (U21: screen-off is background, and background
  pauses every key-using step).
- **Disk.** The runner builds arm64 debug only, without debuginfo
  (`CARGO_PROFILE_DEV_DEBUG=0`, `CARGOKIT_SKIP_EMULATOR_ABIS=true`). Keep
  about 15 GB free.
- **Evidence.** Each round writes to `$TMPDIR/pusd-device-round-<time>`
  (`--out DIR` to choose). `summary.json` digests it: memory peaks, socket
  totals, events, checkpoints, the release verdict and the keyed RPC scans.
- **What the owner provides.**

  | Needed for | Deliverable |
  |---|---|
  | `--m5`, `--m8-route` (forward) | Testnet ZEC on the round's wallet; the testnet maker and relayer (E8) |
  | `--m6`, `--m7`, `--m8-route` (reverse, send) | Private USD that an M5 round left in the wallet |
  | `--m7` | A Sepolia `0x` address of the owner's to withdraw to (`--m7-to`) |
  | `--deposits` | Private tUSD (`0x64c4…727c`) that an M5 round left in the wallet: `--deposits-usd` (default 3) per deposit, plus a few cents of relayer fee |
  | `--keyed-rpc` | The keyed RPC JSON (E6), outside the repo or gitignored |
  | The kill-switch run (M-13) | The flag URL (E7) |
  | Mainnet release QA | Mainnet keyed RPC (E6), a small mainnet balance, and the owner's sign-off (M8.7) |

- **Secrets.** The keyed RPC JSON is the only secret. Pass it only as a
  file. Never paste its URL into a shell, an issue or a log. The runner
  refuses a JSON that git tracks, or one inside the repo that is not
  gitignored.

## Automated rounds (testnet and Sepolia)

Run them in this order. Each command starts with
`ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh`.

1. **M3: the wallet, balance, Tor and lock.** No flags. It resets this
   build's testnet wallet and creates a new one (passcode `111111`; the
   mnemonic is never printed). It then runs the M3 checks and the R8
   release-build check, and leaves a debug build installed.
2. **Fund the wallet.**
   1. Open Veylor on the phone and unlock it with `111111`.
   2. Copy the receive address.
   3. Send it testnet ZEC (E8): enough for several forward conversions and
      their fees. For example, use 0.5 TAZ with the default
      `--m5-zec 0.01`. This default passed the earlier testnet rounds;
      the maker's live quote still determines whether an amount is accepted.
   4. Wait for the funds to confirm.
3. **M5, M6 and M7 together:**
   `--m5 --m6 --m7 --m7-to 0x… --keyed-rpc <json>`. They run in that order
   and stop at the first failure. M6 and M7 spend the private USD that M5
   bought:
   - M6 needs `--m6-usd` (default 2) plus about 2.5 USDC of fees.
   - M7 sends three times, each needing `--m7-usd` (default 1) plus up to
     2 USDC.

   On Sepolia a spend's change can remain Processing, so each payment may
   need a separate spendable note even when the total balance is sufficient.
   Run `--m5` again to top up before the next spend; a larger single
   conversion does not create independent notes for every later payment.
   M7's `--m7-skip-send` and `--m7-skip-withdraw` let reruns continue after
   topping up. Check **Available**, not just the total private USD balance.
4. **The route round:** `--m8-route --keyed-rpc <json>`. It needs testnet ZEC
   for its own forward conversion, and private USD for its reverse funding
   and its send. `--m8-route-phases forward,send` (any subset) re-runs only
   the phases you name.
5. **Optional, long: `--m6 --m6-refund`.** It waits out the refund deadlines,
   which can take up to 3 hours.

For the M8 round, if the reverse phase leaves no spendable note for the send,
run `--m5 --m8-route --m8-route-phases send` to top up and resume just that
phase. Do not repeat already completed payments only to reach the next phase.

To run steps 3 and 4 as one command:
`--m5 --m6 --m7 --m7-to 0x… --m8-route --keyed-rpc <json>`.

A round that died part-way leaves Tor off at the next start. The M5 and M8
forward phases follow a forward conversion that is already under way. The
M6 round and the M8 reverse and send phases need no conversion under way:
finish it first, from its banner or with `--m5` or `--m6`.

### What the rounds cover

| Item | Flag | What is asserted |
|---|---|---|
| Balance before first use, first sync, address match | none (M3) | The strip shows "—" and no renderer runs. The first-sync percentage shows, then $0. The `0zk` address matches between the page and Rust. |
| Tor first sync and refresh | none (M3) | The route change closes the page and stops the bridge. With Tor on: no direct socket (`check_sockets.py --onionoo`). With Tor off: it works direct again. |
| Lock and unlock | none (M3) | Lock closes the page and leaves no loopback listener. Unlock shows the known balance without reopening the page. |
| R8 release build | none (M3) | It loads `/private-usd` and refreshes. Logcat shows no crash and no missing class. |
| Forward conversion (ZEC → USD) | `--m5` | Through the screens until the deposit is kept. Then: a kill mid-confirmation resumes; no advance runs while locked; it keeps advancing with another account active; the delete warning shows the count; it reaches Paid. |
| Reverse conversion (USD → ZEC) | `--m6` | A lock mid-proof pays nothing. The unpaid conversion, cancelled, ends `CANCELLED`. A new one is paid, settlement is authorized, and it reaches `COMPLETE`. |
| Reverse refund | `--m6 --m6-refund` | A paid conversion, cancelled, ends `REFUNDED` and shows on Refunds. |
| Private send and withdraw | `--m7 --m7-to 0x…` | A send arrives at a second account's `0zk` and stays Processing on Sepolia. The withdrawal reaches the `0x` address. A kill between proving and the post resends the kept bytes, with no new proof and no new row. |
| Deposits (M9) | `--deposits [--deposits-usd 3] [--deposits-twice]` | The account's shown deposit address (EIP-55) and the relayer's pinned terms read. Private tUSD withdrawn to it through the Withdraw screens shields back on its own: the pass signs, keeps and posts it ("Making it private…"), and it lands, believed from the pinned contract's event. The shown address then moves to the next index. With `--deposits-twice`, a second deposit there shields to a note of its own. The events record each deposit's index, transaction, fee and what arrived. |
| Route change in each phase (M8.1) | `--m8-route` | Tor turns on at three points: when the claim starts, while the page proves a reverse payment, and while it proves a send. From the flip on, no sample shows a direct Railgun socket. Once Tor is connected, no sample shows anything but loopback and Tor relays. A proof the flip cut off pays and keeps nothing. Each phase then finishes over Tor (Paid, `COMPLETE`, the send landed, exactly one kept proof). |
| The keyed RPC never leaks (M8.3) | `--keyed-rpc <json>` | No file matches the URL's host and path, or its key. The files scanned: the app's `swaps.db` (with its WAL), `joint.db`, the token state and `shared_prefs`, read with run-as; a final logcat dump; and every log and evidence file of the round. |
| Memory and timing | every round | `sample_device.sh` samples throughout, and `summary.json` reports the peaks. |

The keyed RPC check reads `swaps.db` only once a conversion has created it,
so combine `--keyed-rpc` with `--m5` or a later round. The Railgun page's own
storage (`app_webview`) is not scanned: the page receives the keyed URL by
design (reference §7.3).

## Manual runs

Do each one on testnet first. Then repeat the ones marked **mainnet** in
the release QA. Record the result and the evidence for each in the table at
the end.

| # | Run | Expected |
|---|---|---|
| M-1 | **mainnet** Convert ZEC → private USD from the home strip | The progress screen walks through its steps and ends Paid. The strip and the activity row update. |
| M-2 | **mainnet** Convert private USD → ZEC: Pay, then Authorize settlement | `COMPLETE`, and the ZEC arrives in the shielded balance. |
| M-3 | Forward refund: once the deposit is kept, leave Veylor closed past the claim deadline (hours) | On return the deposit sweeps home, less fees, and the conversion ends `REFUNDED`. It ends Nothing sent if the deposit never left. Nothing is lost while away (plan D9). |
| M-4 | **mainnet** Reverse refund: request the refund of a paid conversion, behind its confirmation sheet | `REFUNDED`, and its row shows on Refunds. |
| M-5 | Rescue: on Refunds, a `REFUNDED` row that offers "Recover refund", behind its sheet | The refund is recovered and the row stays `REFUNDED`. A row is eligible only while its vault holds more than the relayer fee. If none offers it, record "not eligible" and do not force it. |
| M-6 | **mainnet** Send to a `0zk`, then withdraw to a `0x` address | Sent and Withdrawn. The fees match the review. A relayer fee above 2 USDC is refused before any proof. |
| M-7 | Lock mid-flow (mobile locks after 15 min in the background) during a claim, a reverse proof and a send proof | No key is used while locked. The unlock keypad shows. After unlock each one resumes, and a cut-off proof is never paid. |
| M-8 | Background for under 15 min (Home, or screen off) mid-conversion and mid-send | The step pauses and the page stays open. On return it resumes with no double payment. |
| M-9 | Kill (swipe away) mid-deposit, mid-claim, after a reverse proof was submitted, and after a send was kept | Reopen and unlock: each one resumes. There is one deposit, one funding and one send row: never a second payment. |
| M-10 | Account switch with a conversion under way | It keeps advancing for its own account (D14). The other account's strip and screens show that account's data. |
| M-11 | Tor on and off from Settings during each phase, including off mid-phase | It fails closed while Tor starts and resumes on either route. This is the manual counterpart of `--m8-route`. |
| M-12 | Delete an account, or reset, with a conversion under way (testnet, a throwaway account) | The warning shows the number under way. Cancel deletes nothing. Confirm deletes it, and nothing of it remains. |
| M-13 | Kill switch (E7): build with `--dart-define=VIZOR_PRIVATE_USD_FLAG_URL=<owner URL>`, then serve `{"private_usd_available": false}`, then a document without the key, then make the URL unreachable | `false` hides the strip and the entry points. A conversion under way keeps its banner and progress screen and still finishes. A missing key or a failed fetch keeps the last value (available if none). The parsing and fallback are unit-tested in `test/core/config/private_usd_feature_config_test.dart`. |
| M-14 | Hardware account (Keystone or Ledger), and a regtest build | Private USD is hidden. The availability matrix unit-tests this too (progress D-42). |
| M-15 | **mainnet** Beta limit: convert just under, then above, 50 USDC (`maxSwapUsdc` 50) | Under the limit it is accepted. Above it, the server refuses with the amount-refused copy. The limit is the server's: never hard-code it in the app or the tests. |
| M-16 | **mainnet** Measurements (M8.4): release APK size, first Railgun sync time, send and reverse-funding proof times, peak memory | Record them in plan §11 (U14). A first mainnet sync takes about 40 minutes with the screen on (U21). |

## Mainnet release QA

1. **Build.**
   `fvm flutter build apk --release --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define-from-file=<rpc json>`.
   The JSON holds both keyed URLs (E6).
   - Install it on a phone with no personal wallet.
   - Issuer acceptance is per signing digest (E3), which matters once a maker
     requires tokens. Makers don't today (D20); re-check before release
     (U11).
2. **Runs.** Do the manual runs marked **mainnet**, with small amounts,
   and M-15 with the beta limit.
3. **The keyed RPC on mainnet.** A release build is not debuggable, so
   `run-as` cannot read its files: the testnet `--keyed-rpc` round covers
   `swaps.db` (same code, different key). Scan the release build's logs
   instead:
   1. Capture them with `adb logcat -d -v threadtime > <dir>/logcat-mainnet.txt`.
   2. Scan them with `python3 -I scripts/private-usd/device_round.py keyed-rpc-scan --file <rpc json> --out <dir> --logs`.

   The scan exits 0 when clean and 1 when it found a pattern. It never
   prints the URL or the key.
4. **Sign-off.** Turn `VIZOR_PRIVATE_USD_ENABLED` on for release builds only
   after the owner signs off (M8.7).

## Results

| Date | Build (git) | Network | Item | Result | Evidence |
|---|---|---|---|---|---|
| | | | | | |
