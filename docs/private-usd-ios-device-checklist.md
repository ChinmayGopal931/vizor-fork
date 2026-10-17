# Private USD device checklist (iOS)

The end-to-end runs for Private USD on iOS (plan MI8.5, §10), in this order:

1. the simulator smoke run, for every host change
2. the iPhone rounds, on testnet and Sepolia, for every release candidate
3. the manual runs
4. the mainnet release QA, last

MI8 is done when this checklist passes on mainnet with the beta limits.

Plan: `docs/private-usd-ios-plan.md` (§3.5 invariants, §10 test strategy, MI8). Progress and deviations: `docs/private-usd-ios-progress.md`. The Android checklist (`docs/private-usd-device-checklist.md`) is the model: its rounds and manual runs apply here, with the iOS differences below.

## Before you start

- **The iPhone** (EI1): iOS 17 or later, unlocked, and trusted by this Mac (Xcode, Devices and Simulators).
- **The simulator** proves function only. It is no evidence for memory, timing or the phone's radios.
- **Never install over a real wallet** (plan XI11). A development build signed with the App Store bundle ID replaces an App Store Vizor and inherits its data container.
  - If the iPhone has an App Store Vizor, build with the side-by-side bundle ID (iOS reference §8.7).
  - The runner refuses an iPhone whose installed Vizor is not a development build.
- **Signing** (EI2): the owner's team, with profiles for Runner and SyncWidget.
- **The screen.** iOS has no `svc power stayon`. For the round, set Settings, Display & Brightness, Auto-Lock to Never, and restore it afterwards. During key-using steps the app also keeps the screen on itself (A-plan X8).
- **Disk.** Keep 5–6 GB free beyond Xcode's cache, and build with `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0`.
- **Capturing traffic** (the Tor checks):
  1. `rvictl -s <udid>`
  2. `sudo tcpdump -i rvi0 -n -w <file>`
  3. `rvictl -x <udid>` afterwards

  The runner classifies every remote against the Tor relay list (onionoo), like `check_sockets.py --onionoo`. Loopback traffic, the bridge hop, never appears on `rvi0`.
- **Memory.** Xcode's Debug navigator, or `xcrun xctrace` with the Activity Monitor template. Measure both the app and `com.apple.WebKit.WebContent`.
- **What the owner provides.** Everything in the Android table (E6, E7, E8, N2, and a Sepolia `0x` address), plus EI1 and EI2.
- **Secrets.** As on Android: the keyed RPC JSON only as a gitignored file, never pasted into a shell, an issue or a log.

## Simulator smoke (every host change)

1. Run the app on the iPhone 17 Pro simulator with the three defines (plan "Commands").
2. Open `/private-usd`. The first sync on Sepolia completes, and the address matches Rust's.
3. Turn Tor on. `lsof -nP -iTCP -a -p <app pid>` shows only loopback and Tor relays. The simulator's app is a Mac process, so the Mac's tools see it.
4. Lock the app. The page closes, and no loopback listener remains.
5. Background it for five minutes, then return. The page works again (plan XI14).
6. Reset the wallet. The page's data store is removed.

## iPhone rounds (testnet and Sepolia)

Each command starts with `scripts/private-usd/ios/run_device_round.sh --device <udid>` (written in MI3.5). The flags mirror Android's: `--m5`, `--m6`, `--m6-refund`, `--m7 --m7-to 0x…`, `--m8-route` and `--keyed-rpc <json>`.

1. **M3: the wallet, the balance, Tor and the lock.** No flags. It creates the round's testnet wallet; the mnemonic is never printed.
2. **Fund the wallet**, as in step 2 of the Android checklist.
3. **M5, M6 and M7 together:** `--m5 --m6 --m7 --m7-to 0x… --keyed-rpc <json>`.
4. **The route round:** `--m8-route --keyed-rpc <json>`.
5. **Optional, long:** `--m6 --m6-refund`, which waits out the refund deadlines (up to 3 hours).

### What the rounds cover

The Android table applies, with this iOS evidence:

| Item | iOS evidence |
|---|---|
| Balance before first use, first sync, address match | As on Android |
| Tor first sync and refresh | The `rvi0` capture: once Tor is connected, only Tor relays |
| Lock and unlock | No listener on the bridge's port afterwards (simulator: `lsof`; iPhone: the app's own log of the bridge stopping, in a debug build) |
| Release build | `fvm flutter build ios --release` (or a TestFlight build) loads `/private-usd` and refreshes, and the crash log stays empty |
| Background and the bridge | After 5 and after 20 minutes away, the page works again; the second case also locks |
| Forward, reverse, sends, route changes | As on Android, through the iOS runner |
| The keyed RPC never leaks | The device logs (`log collect --device`) and, in a development build, the app container (Xcode, Download Container) for `swaps.db` and its WAL |
| Memory and timing | The app and `com.apple.WebKit.WebContent`, sampled throughout and reported in `summary.json` |

## Manual runs

Do each of Android's M-1 to M-16 on the iPhone, and record its iOS result. iOS adds these:

| # | Run | Expected |
|---|---|---|
| I-1 | Face ID, Control Center or the notification shade during a first sync and during a claim. The app goes `inactive`, not to the background | Nothing pauses, and the step finishes |
| I-2 | The power button (screen lock) mid-claim and mid-proof | It goes to the background and the step pauses. On return, and after unlocking if 15 minutes passed, it resumes. A proof cut short is never paid |
| I-3 | Swipe it away in the app switcher: mid-deposit, mid-claim, after a reverse proof was submitted, and after a send was kept | As Android M-9: one deposit, one funding and one send row, never a second payment |
| I-4 | An incoming call, or Siri, during a reverse-funding proof | As I-1 if the app stays inactive; as I-2 if it goes to the background |
| I-5 | Low Power Mode on during a first sync and during a proof | Both complete, more slowly. Record the times |
| I-6 | Memory pressure: open several heavy apps during a first sync, then return | The page either carries on, or reports its termination and reopens on next use. No crash |
| I-7 | An iOS 16 device or simulator, if one is available | Private USD is hidden, and nothing else changes |
| I-8 | Backups: after a first sync and a conversion, check the backup's contents (Settings, iCloud, Manage Storage, Backups, or a Finder backup) | The `private_usd_*` folders and the page's store are not in the backup (DI6) |
| I-9 | Safari's Web Inspector against a release build | The page is not inspectable (XI12) |
| I-10 | Twenty minutes away mid-first-sync, then return and unlock | The bridge is restarted (XI14). The first sync resumes or restarts, and never shows a balance it hasn't read |

## Mainnet release QA

1. **Build.** `fvm flutter build ipa --release --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define-from-file=<rpc json>`. Install it through TestFlight, internal testers only until DI3 is settled.
2. **Runs.** On the iPhone, with small amounts: the manual runs marked **mainnet** in the Android checklist (M-1, M-2, M-4, M-6, M-15 and M-16).
3. **The keyed RPC on mainnet.** A release build's container cannot be read, so the testnet `--keyed-rpc` round covers `swaps.db`: the same code with a different key. On the release build:
   1. Collect the device logs.
   2. Scan them with `python3 -I scripts/private-usd/device_round.py keyed-rpc-scan --file <rpc json> --out <dir> --logs`, which exits 0 when clean and never prints the URL or the key.
4. **Sign-off.** Once DI3 (licensing) and DI4 (the review notes) are settled and the owner has signed off, turn `VIZOR_PRIVATE_USD_ENABLED` on for iOS release builds.

## Results

| Date | Build (git) | Device and iOS | Network | Item | Result | Evidence |
|---|---|---|---|---|---|---|
| | | | | | | |
