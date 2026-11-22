# Releases and app identities

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

## Google Play opt-out (VIZOR_DEGOOGLED)

Android builds include Google Play integrations by default. Direct APK and
F-Droid builds explicitly pass `--dart-define=VIZOR_DEGOOGLED=true`; the
reproducible APK builder exposes this as `--degoogled`. Dart and Gradle read
the same define. When enabled, Android review scheduling is disabled and the
Google Play review SDK and implementation are excluded from the build. iOS
reviews and desktop behavior are unaffected. F-Droid's wrapper always passes
`--degoogled` to match deployment's direct APK build inputs.

Mobile review eligibility is classified once from the first successful startup
snapshot and persisted in `vizor_app_review_history_v1`. Existing wallet users
skip the three-launch wait; new users retain it even after creating a wallet.
Both require explicit usage and two idle seconds on home, with at most two API
attempts and a seven-day retry interval. Legacy history keeps its attempt budget
and dates when the classification field is added. Blocked startup must not be
classified as a new user; retry recovery supplies the successful snapshot.

## Android Package (VIZOR_APPLICATION_ID)

Google Play lists Veylor as `com.veylor.app`; the tree's development id is
`com.keplr.vizor`. A Play bundle passes
`--dart-define=VIZOR_APPLICATION_ID=com.veylor.app`, which Gradle reads from
the forwarded dart-defines like `VIZOR_DEGOOGLED`; without it the build keeps
the development id. Never edit `applicationId` in place for a release. The
Play bundle is otherwise `flutter build appbundle --release` with
`--target-platform android-arm64,android-arm,android-x64` (every ABI the
plugins ship, or Play serves some devices a build without the core), signed
with the upload keystore through the `ANDROID_KEYSTORE_*` variables, a build
number above the last upload, and the keyed RPC JSON through
`--dart-define-from-file`. It passes
`--dart-define=VIZOR_WALLET_LINK_BACKEND_URL=https://functions.vizor.cash`,
the relay Veylor's desktop builds create their wallet-link packages on, and
so does the iOS TestFlight build: without it the app's default is
`http://localhost:3000`, which reaches nothing on a phone, so scanning a
desktop's wallet link fails. The Play and TestFlight builds up to 2026-11-22
passed none. Keystore aliases do not depend on the id, but
app-link verification (`assetlinks.json`) names the shipped id.

## Android direct APK (verifiable)

Veylor's APK for direct download, beside Google Play, is the same app
(`com.veylor.app`), built so that anyone can check it comes from this
repository's code. Play's copy carries Google's Play App Signing key and this
one Veylor's APK-only key, so neither updates the other; a user switches by
uninstalling.

- **What it compiles.** The Play build's settings plus `VIZOR_DEGOOGLED=true`:
  `scripts/build-android-reproducible.sh --flavor veylor --universal
  --build-name 1.0.3 --build-number 10 --signing unsigned --degoogled`. The
  flavor defines `VIZOR_FORM_FACTOR=mobile`, `VIZOR_PRIVATE_USD_ENABLED=true`,
  `ZCASH_DEFAULT_NETWORK=main`, `VIZOR_APPLICATION_ID=com.veylor.app` and
  `VIZOR_WALLET_LINK_BACKEND_URL=https://functions.vizor.cash` (since
  2026-11-22: the relay Veylor's desktops use, as above), and nothing else:
  the price URL keeps its default, and there is no keyed RPC file (a build
  anyone can reproduce holds no secret). Neither
  build defines `VIZOR_RELEASE_VERSION`, so both show v0.0.0 in Settings; pass
  `--release-version` here once the Play build does. Upstream's builds keep
  `--flavor vizor`, the default, unchanged (`scripts/test_fdroid_tools.py`
  pins both commands).
- **One universal APK** with all three ABIs, versionCode the Play build's
  number: one file for the website to link and for a user to check. It costs
  size: 1.0.3 is 299 MB (arm64 alone would be about 123 MB), and a phone keeps
  the whole file, the other ABIs' libraries too. Without `--universal` the
  builder still makes one APK per ABI.
- **The build.** `.github/workflows/veylor-android.yml`, dispatched with
  `version` and `build_number` (`gh workflow run veylor-android.yml --ref main
  -f version=1.0.3 -f build_number=10`), builds the APK twice from scratch, on
  ubuntu-22.04 and ubuntu-24.04, from different checkout and toolchain paths,
  with no caches. Each build installs the pinned toolchain with
  `scripts/veylor-android-release/install-toolchain.sh`: Temurin JDK, the
  Android SDK packages, Flutter at `scripts/release-config/flutter-sdk.json`,
  Rust at `android-reproducible-rust-version.txt`. Only when the two APKs are
  byte-identical does the run attest the APK
  (`actions/attest-build-provenance`) and keep it as the artifact
  `veylor-<version>-<build>-unsigned`; otherwise it lists what differs
  (`scripts/veylor-android-release/compare_apks.py`, then diffoscope) and
  fails. The run signs and publishes nothing.
- **Signing, on the owner's Mac.** `gh run download <run> -n
  veylor-1.0.3-10-unsigned -D <dir>`, then `scripts/sign-veylor-apk.sh
  --unsigned <dir>/veylor-1.0.3-10-unsigned.apk`. The script:
  - checks the APK's attestation and contents, then signs a copy with
    apksigner (v3, the build's alignment kept; apksigner leaves v2 out, since
    minSdkVersion 30 verifies v3 on every device that installs it);
  - uses `~/keys/veylor/veylor-apk.jks` (PKCS12, alias `apk`), whose password
    lives only in the login Keychain ("Veylor Android APK keystore", account
    `veylor-apk`) and reaches apksigner in its environment, never a command
    line or a log; the key never goes to GitHub;
  - refuses any certificate but the one in
    `scripts/release-config/veylor-android-certificate-sha256.txt`;
  - checks with apksigcopier (pinned with hashes in
    `scripts/veylor-android-release/requirements.txt`) that the signed APK is
    the unsigned one plus the signature, byte for byte;
  - writes `veylor-X.Y.Z-N.apk`, `veylor-X.Y.Z-N-unsigned.apk` and
    `SHA256SUMS` to `dist/veylor-android/vX.Y.Z/`.
- **Publishing.** A release `veylor-android/vX.Y.Z` at the commit the
  attestation names, with those three files and the notes from
  `release_notes/veylor-android-vX.Y.Z.md`; the script prints the
  `gh release create` command. Never latest (`--latest=false`): the Mac's DMG
  link and update feed resolve through "latest". The website links the files
  by their tag.
- **Paths.** Both flavors build under `/tmp/vizor-android-reproducible`: each
  `libapp.so` embeds the canonical source path (Dart's plugin registrant), so a
  rebuild must build there too, and the Rust library carries its cargo home
  only as the remapped `/vizor/cargo`. Nothing of the checkout's, the
  toolchain's or the home directory's location reaches the APK (the
  `/home/runner` in the Railgun page's curve25519 wasm comes with that
  committed file); each CI build reports what it found (`host-paths-*.txt` in
  the artifact).

What a user runs to check a download (the release notes carry this):

1. `gh attestation verify veylor-1.0.3-10-unsigned.apk --repo
   ChinmayGopal931/vizor-fork --signer-workflow
   ChinmayGopal931/vizor-fork/.github/workflows/veylor-android.yml`: this
   repository's workflow built the file. Outside a terminal it prints nothing
   and only its exit status tells; `--format json --jq
   '.[].verificationResult.signature.certificate.sourceRepositoryDigest'`
   prints the commit, which must be the release tag's.
2. `apksigcopier compare veylor-1.0.3-10.apk --unsigned
   veylor-1.0.3-10-unsigned.apk` (`pip install apksigcopier`, with the Android
   SDK's `apksigner` on PATH): the signed APK is that build plus a signature,
   as F-Droid checks reproducible builds.
3. `apksigner verify --print-certs veylor-1.0.3-10.apk`: `Signer #1
   certificate SHA-256 digest:
   83f16e2037b09e731e51b3472466db43c4a962ada1fb4e40eaa4c3215a2174f5`
   (`83:F1:6E:20:…:21:74:F5`), Veylor's APK key.
4. To rebuild it on Linux x86_64: check out the release's tag, run
   `scripts/veylor-android-release/install-toolchain.sh --prefix <dir>
   --accept-android-sdk-licenses` and `. <dir>/env.sh`, then the builder
   command above. `build/app/outputs/flutter-apk/app-release.apk` has the
   unsigned APK's SHA-256, and `apksigcopier compare` takes it in place of the
   downloaded unsigned APK.

## Desktop identity (VIZOR_APPLICATION_ID)

Veylor's desktop apps are `com.veylor.desktop` ("Veylor") and
`com.veylor.desktop.testnet` ("Veylor Testnet", built with
`--dart-define=ZCASH_DEFAULT_NETWORK=test`), with the phone's icon (master:
the 1024 px image in `ios/Runner/Assets.xcassets/AppIcon.appiconset`). As on
the phones, the tracked files keep upstream's identity (`com.keplr.vizor`;
`app.keplr.vizor` on Linux) and a build-time switch selects Veylor's. Desktop
builds cannot read dart-defines natively, so each platform takes the id its
own way, and a malformed or unknown id fails the build:

- **macOS**: `scripts/macos-identity.sh com.veylor.desktop` writes the ignored
  `macos/Runner/Configs/FlavorOverrides.xcconfig` (name, bundle id,
  `VeylorAppIcon`, copyright, signing). It stays until
  `scripts/macos-identity.sh --clear`, and a fastlane run replaces it. Then
  `fvm flutter run -d macos` or `fvm flutter build macos --release`.
  - **Signing:** Veylor builds sign with Zapp LLC's team (`63UVRFCV97`): its
    Apple Development certificate and the Mac development profile "Veylor
    Desktop Mac Development". The profile lists the Macs a build runs on. To
    add a Mac, register it and regenerate the profile through the App Store
    Connect API. With `--release`, Release builds sign for distribution
    instead and compile Sparkle in ("Veylor macOS release" below).
  - **Testnet:** the testnet id has no profile yet.
  - **Where signing lives:** the Runner target's signing is set in
    `AppInfo.xcconfig`, not the project file, so the overrides can replace it.
    Upstream's release lane still writes its own settings into the project.
- **Linux**: `VIZOR_APPLICATION_ID=com.veylor.desktop fvm flutter run -d linux`
  (or `fvm flutter build linux --release`). CMake sets the GTK application id,
  the desktop entry, the hicolor icons (named by the id) and the executable
  `veylor`, which a `vizor` link serves to `flutter run` (`BINARY_NAME` stays a
  literal). The rename keeps the data apart: path_provider_linux names the
  support directory after the executable when it cannot load `libgio-2.0.so`,
  as on most machines without development packages.
  - **Builds run on GitHub Actions** (`.github/workflows/veylor-linux.yml`, on
    the fork, for pushes to `feat/linux-desktop` and on demand), never on the
    Mac. Each architecture builds on its own runner, x86_64 on `ubuntu-22.04`
    and ARM64 on `ubuntu-24.04-arm`, through upstream's lane:
    `fastlane linux release` with `VIZOR_LINUX_FLAVORS=veylor`, which runs
    `scripts/build-linux-release.sh` and `scripts/package-linux-appimage.sh`.
  - **What it builds:** mainnet, the desktop form factor, and
    `VIZOR_PRIVATE_USD_ENABLED=true`, which the build script passes on as a
    define. Shielded USD stays hidden until Linux has a Railgun host
    (`privateUsdPlatformHostsPage`). Flutter comes from `.fvmrc` through fvm,
    checked against `scripts/release-config/flutter-sdk.json`; Rust is stable,
    as cargokit picks it. After the build, the job reads the defines back from
    Flutter's generated config and fails unless they are those, with the
    `veylor` flavor and no keyed RPC URL.
  - **What it keeps:** `Veylor-linux-<arch>.AppImage` and its `.sha256`, as a
    workflow artifact for 30 days. Nothing is published.
  - **Signing:** the AppImages are unsigned. `LINUX_APPIMAGE_UNSIGNED=true` is
    the switch (`fastlane/linux/README.md`); an AppImage that embeds update
    information refuses it.
  - **Caches:** the Cargo registry and pub caches (shared by both
    architectures) and an sccache directory per architecture, each saved once
    per lockfile. Cargokit's target directory lies under `build/linux`, which
    the build script deletes first, so sccache is what carries Rust across
    runs.
- **Windows**: `$env:VIZOR_APPLICATION_ID = "com.veylor.desktop"`, then
  `fvm flutter run -d windows` (or `fvm flutter build windows --release`).
  CMake sets the version resource (company `com.veylor`, product `Veylor`,
  copyright Zapp LLC), the
  window title, `veylor_app_icon.ico` and the storage prefix `Veylor`, and
  fails if an inherited `VIZOR_WINDOWS_STORAGE_PREFIX`, `_COMPANY_NAME` or
  `_PRODUCT_NAME` disagrees. `Vizor.exe` keeps its name.

Every store follows from the identity, never from a renamed key, so nothing is
shared with an installed Vizor: the macOS container and Keychain access group,
the support directory (wallet DB and companions, Tor, Private USD,
diagnostics, Linux and Windows preferences), libsecret's
`<id>/FlutterSecureStorage` schema, the Windows Credential Manager prefix, and
the single-instance locks (D-Bus name and `$XDG_RUNTIME_DIR` lock on Linux, the
`%LOCALAPPDATA%` lock and activation message on Windows). Both apps register
`zcash:`; the OS hands a link to one of them. Code identifiers (`vizor_*` keys,
`VIZOR_*` flags, `Vizor*` names, `vizor.cash` domains) stay.

Packaging follows the same switch: the `veylor` and `veylor-testnet` flavors of
`fastlane mac|linux|windows` (`VIZOR_MACOS_FLAVOR`, `VIZOR_LINUX_FLAVOR`,
`VIZOR_WINDOWS_FLAVOR`), `scripts/build-linux-release.sh --flavor veylor` and
`scripts/package-windows-velopack.ps1 -ApplicationId com.veylor.desktop` make
`Veylor-macos.dmg`, `Veylor-linux-<arch>.AppImage` and the
`com.veylor.desktop` Velopack package; `scripts/package-linux-deb.sh` makes the
`veylor` and `veylor-testnet` .debs (`/opt/<package>`, side by side, with the
AppArmor profile Shielded USD needs on Ubuntu), which Veylor's Linux CI builds
beside each AppImage. Those packages have no updates: the
fastlane builds leave Sparkle out, the Linux check is off, and Windows hides
its updater in a build without a feed key. The lanes keep upstream's signing,
Apple team, match and release targets, and the macOS lane refuses to sign a
Veylor flavor. Veylor's macOS release has its own signing, notarization and
update feed, and Linux's comes from CI (both below); Windows has no Veylor
release yet.

### Veylor macOS release

`scripts/release-veylor-macos.sh --version 0.9.0 --build-number 1` builds a
release from a clean tree and publishes nothing:

- **Identity and signing.** For the build it selects
  `scripts/macos-identity.sh com.veylor.desktop --release`, then restores the
  earlier overrides. Release then signs with "Developer ID Application: Zapp
  LLC (63UVRFCV97)" and the "Veylor Desktop Developer ID" profile
  (MAC_APP_DIRECT), which grants the application identifier and keychain
  entitlements. The Runner target's Release settings add the hardened runtime
  and a secure timestamp. The script refuses any identity but Zapp LLC's.
- **Build.** Mainnet, Shielded USD on, the public RPC (no keyed RPC file):
  `ZCASH_DEFAULT_NETWORK=main`, `VIZOR_PRIVATE_USD_ENABLED=true`,
  `VIZOR_RELEASE_VERSION`, and `VIZOR_RELEASE_REPOSITORY` set to the fork.
  The version comes from `--build-name` and `--build-number`, never
  pubspec's, which the phones use. `flutter build macos --config-only` and
  `xcodebuild` build into `build/veylor-release`, so a Veylor running from
  `build/macos` keeps its bundle.
- **Sparkle.** `SPARKLE_ENABLED` is compiled in. A staged copy of the app gets
  `SUFeedURL`
  (`https://github.com/ChinmayGopal931/vizor-fork/releases/latest/download/appcast.xml`),
  `SUPublicEDKey`, a required feed signature and verification before
  extraction, as upstream's lane sets them. Sparkle's helpers and the app are
  then signed again. Upstream's update-over-Tor handling is unchanged.
- **Notarization.** `notarytool` with the App Store Connect key named in
  `~/dev/zapp/ios-zapp/fastlane/.env`, read in place (never copied, printed
  or committed). The app and the DMG are notarized, stapled, and checked with
  `spctl --assess` and `stapler validate`. Apple can take hours over a new
  team's first submissions: the script waits up to 12 hours, and if it stops
  first, the same command with `--resume` waits on the same submissions
  without signing again.
- **DMG.** `Veylor-macos.dmg`, volume "Veylor", with the neon background in
  `macos/Packaging/DMG/veylor/` (drawn by `render-background.swift`). dmgbuild
  (pinned with hashes in `scripts/veylor-macos-release/requirements.txt`)
  writes the window layout itself; nothing scripts Finder.
- **Appcast.** `generate_appcast` and `sign_update` with Veylor's EdDSA key:
  the login Keychain's `veylor-desktop` account, backed up (mode 600) in
  `~/keys/veylor/sparkle/`, which the script uses first. Never print or
  commit it. `check_appcast.py` checks the feed before it ships.

The assets land in `dist/veylor-macos/vX.Y.Z/`: `Veylor-macos.dmg`,
`appcast.xml`, `Veylor-macos.md` (the Sparkle release notes, from
`release_notes/veylor-macos-vX.Y.Z.md`), `SHA256SUMS`, `release-info.txt` and
the logs. Publish the first three unchanged to a release on the fork tagged
`veylor-macos/vX.Y.Z`, as a full release, not a pre-release or a draft: the
website's `releases/latest/download/Veylor-macos.dmg` and the feed resolve
through "latest", so any later release that becomes latest carries
`appcast.xml` too. The DMG's name never carries the version, and each release
takes a higher build number.

### Veylor Linux release

`gh workflow run veylor-linux.yml --ref main -f public_release=true` builds
`VEYLOR_VERSION` (set in the workflow) for x86_64 and aarch64 and publishes it.
A run without `public_release` stays `-internal.<run>` and publishes nothing.

- **Attested.** Every AppImage and .deb gets signed build provenance
  (`actions/attest-build-provenance`): its SHA-256 bound to this repository,
  the commit and the workflow run.
- **Published by the run.** The `publish` job checks each mainnet file's
  attestation and writes `SHA256SUMS`. It then creates the release
  `veylor-linux/vX.Y.Z`, tagged at the commit it built, with the notes from
  `release_notes/veylor-linux-vX.Y.Z.md`. The files on a release are the ones
  the run built; none passes through a computer.
- **A published version keeps its files.** A release already there takes
  files only from a run of its tag's commit (a publish that failed partway, run
  again). Anything else takes a new version: new files under a published name
  would fail the SHA-256 check of everyone who downloaded the old ones.
- **Never cancelled.** A push cancels the CI run before it, but a
  `public_release` run has a concurrency group of its own.
- **Never latest** (`--latest=false`): the Mac's DMG link and update feed
  resolve through "latest". The website links the Linux files by their tag.
- **Anyone checks a download:**
  `gh attestation verify <file> --repo ChinmayGopal931/vizor-fork`.
- **Not yet:** the AppImages are unsigned (`LINUX_APPIMAGE_UNSIGNED`), the .debs
  come from no repository, and nothing updates itself.

## Release Notes

When asked to prepare user-facing release notes or a changelog for a release,
read `release_notes/README.md` and create `release_notes/vX.Y.Z.md`.
Unless the request explicitly says otherwise, draft desktop release notes for
Windows, Linux, and macOS from desktop user-facing changes only. Exclude
mobile-only changes. Veylor's macOS releases use
`release_notes/veylor-macos-vX.Y.Z.md` ("Veylor macOS release").
