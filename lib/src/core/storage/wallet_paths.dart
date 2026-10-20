import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_secure_store.dart';
import 'device_backup.dart';

const kPaymentLinkClaimWalletDirectoryPrefix = 'payment_link_claim_';

/// Claim-wallet directories are named
/// `payment_link_claim_<network>_<sha256>`. The hash cannot be reversed, so the
/// network segment is the only thing that lets a sweep delete one network's
/// claim wallets without touching another's retained recovery state.
final _paymentLinkClaimWalletDirectoryPattern = RegExp(
  r'^payment_link_claim_[a-z0-9]+_[0-9a-f]{64}$',
);

String paymentLinkClaimWalletDirectoryNameFor({
  required String network,
  required String identityHash,
}) => '$kPaymentLinkClaimWalletDirectoryPrefix${network}_$identityHash';

RegExp _paymentLinkClaimWalletDirectoryPatternFor(String network) => RegExp(
  '^$kPaymentLinkClaimWalletDirectoryPrefix'
  '${RegExp.escape(network)}_[0-9a-f]{64}\$',
);

Future<Directory> getWalletSupportDirectory() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return dir;
}

Future<String> getWalletDbName() async {
  return AppSecureStore.instance.ensureWalletDbName();
}

Future<String> getWalletDbPath() async {
  final dir = await getWalletSupportDirectory();
  final dbName = await getWalletDbName();
  return '${dir.path}${Platform.pathSeparator}$dbName';
}

/// Resolves the recorded wallet path without assigning a new database name.
/// A reset or fresh install with no recorded wallet returns null. Storage
/// failures propagate so callers cannot mistake unknown state for no wallet.
Future<String?> getExistingWalletDbPath({
  AppSecureStore? secureStore,
  Future<Directory> Function() resolveSupportDirectory =
      getApplicationSupportDirectory,
}) async {
  final name = await (secureStore ?? AppSecureStore.instance).readPlain(
    kWalletDbNameKey,
  );
  if (name == null || name.isEmpty) return null;
  final directory = await resolveSupportDirectory();
  return '${directory.path}${Platform.pathSeparator}$name';
}

Future<String> getTorDataDirectoryPath() async {
  final dir = await getWalletSupportDirectory();
  return '${dir.path}${Platform.pathSeparator}tor';
}

/// Deletes claim-wallet directories for [network] only, or for every network
/// when it is null.
Future<void> deletePaymentLinkClaimWalletDirectories({
  String? network,
  Future<Directory> Function() resolveSupportDirectory =
      getWalletSupportDirectory,
  Future<void> Function(Directory directory)? deleteDirectory,
}) async {
  final pattern = network == null
      ? _paymentLinkClaimWalletDirectoryPattern
      : _paymentLinkClaimWalletDirectoryPatternFor(network);
  final supportDirectory = await resolveSupportDirectory();
  if (!await supportDirectory.exists()) return;

  Object? firstError;
  StackTrace? firstStackTrace;
  await for (final entity in supportDirectory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final directoryName = entity.path.split(Platform.pathSeparator).last;
    if (!pattern.hasMatch(directoryName)) {
      continue;
    }
    try {
      if (deleteDirectory == null) {
        await entity.delete(recursive: true);
      } else {
        await deleteDirectory(entity);
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Suffix of the directory beside a wallet database that holds its private
/// transparent recovery companions (`{dbPath}.tpir`). Rust creates it lazily
/// and owns its contents; they are rebuildable, so deleting it loses no funds.
const kTransparentRecoveryCompanionSuffix = '.tpir';

/// The companion directory of the wallet database at [dbPath].
String transparentRecoveryCompanionDirectory(String dbPath) =>
    '$dbPath$kTransparentRecoveryCompanionSuffix';

/// Deletes companion directories in the wallet support directory that belong
/// to no current wallet: every `*.tpir` directory except that of
/// [currentDbPath], or all of them when it is null.
///
/// Companions record which transparent addresses had activity, so one left
/// behind by an earlier wallet is not kept. Attempts every directory and then
/// rethrows the first failure.
Future<void> deleteOrphanCompanionDirectories(
  String? currentDbPath, {
  Future<Directory> Function() resolveSupportDirectory =
      getWalletSupportDirectory,
  Future<void> Function(Directory directory)? deleteDirectory,
}) async {
  final current = currentDbPath == null
      ? null
      : transparentRecoveryCompanionDirectory(
          currentDbPath,
        ).split(Platform.pathSeparator).last;
  final supportDirectory = await resolveSupportDirectory();
  if (!await supportDirectory.exists()) return;

  Object? firstError;
  StackTrace? firstStackTrace;
  await for (final entity in supportDirectory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final directoryName = entity.path.split(Platform.pathSeparator).last;
    if (!directoryName.endsWith(kTransparentRecoveryCompanionSuffix) ||
        directoryName == current) {
      continue;
    }
    try {
      if (deleteDirectory == null) {
        await entity.delete(recursive: true);
      } else {
        await deleteDirectory(entity);
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Scoped to both the wallet instance and network; never overlaps claim DBs.
Future<String> getGiftCardTrackingDbPath(String network) async {
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(network)) {
    throw ArgumentError.value(network, 'network');
  }
  final support = await getWalletSupportDirectory();
  final walletName = await getWalletDbName();
  final directory = Directory(
    '${support.path}${Platform.pathSeparator}gift_card_tracking_${walletName}_$network',
  );
  await directory.create(recursive: true);
  return '${directory.path}${Platform.pathSeparator}observer.db';
}

Future<void> deleteGiftCardTrackingDirectories() async {
  final support = await getWalletSupportDirectory();
  await for (final entity in support.list(followLinks: false)) {
    if (entity is Directory &&
        entity.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('gift_card_tracking_')) {
      await entity.delete(recursive: true);
    }
  }
}

const _privateUsdPrefix = 'private_usd_';
const _privateUsdTokenStorePrefix = 'private_usd_tokens_';

// The Private USD directories this process has kept out of backups.
final _privateUsdBackupMarked = <String>{};

void _checkPrivateUsdNetwork(String network) {
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(network)) {
    throw ArgumentError.value(network, 'network');
  }
}

Future<Directory> _privateUsdDirectory(
  String network,
  String walletName,
) async {
  final support = await getWalletSupportDirectory();
  return Directory(
    '${support.path}${Platform.pathSeparator}$_privateUsdPrefix${walletName}_$network',
  );
}

/// Private USD's `swaps.db` and `joint.db` directory for one wallet and
/// network: `<support>/private_usd_<walletDbName>_<network>`.
///
/// The swap records hold relayer tickets and token blinding secrets, so on iOS
/// the directory stays out of iCloud and device backups, marked before
/// anything is written in it. The mark goes with the directory, so it is set
/// whenever the directory is made, and once per process for one made earlier.
/// A failed mark is tried again on the next call: a weaker backup posture must
/// not stop a conversion that is under way.
Future<String> getPrivateUsdDirPath(
  String network, {
  Future<void> Function(String directory) excludeFromBackup =
      excludeFromDeviceBackup,
}) async {
  _checkPrivateUsdNetwork(network);
  final directory = await _privateUsdDirectory(
    network,
    await getWalletDbName(),
  );
  final made = !await directory.exists();
  await directory.create(recursive: true);
  if (_privateUsdBackupMarked.add(directory.path) || made) {
    try {
      await excludeFromBackup(directory.path);
    } catch (error) {
      _privateUsdBackupMarked.remove(directory.path);
      if (kDebugMode) {
        debugPrint('Private USD directory not kept out of backups: $error');
      }
    }
  }
  return directory.path;
}

/// [getPrivateUsdDirPath] when that directory already exists, else null.
/// Reads that must not create anything use it: a wallet that never
/// converted has no Private USD directory (and desktop never gets one).
/// Like [getExistingWalletDbPath], it never assigns a wallet database name.
Future<String?> getExistingPrivateUsdDirPath(String network) async {
  _checkPrivateUsdNetwork(network);
  final walletName = await AppSecureStore.instance.readPlain(kWalletDbNameKey);
  if (walletName == null || walletName.isEmpty) return null;
  final directory = await _privateUsdDirectory(network, walletName);
  return await directory.exists() ? directory.path : null;
}

/// Removes every wallet's Private USD directory (swap records and joint
/// accounts), for a full reset. Attempts every directory and then rethrows
/// the first failure, so one that cannot be deleted does not leave the others'
/// swap secrets on disk.
Future<void> deletePrivateUsdDirectories() async {
  final support = await getWalletSupportDirectory();
  Object? firstError;
  StackTrace? firstStackTrace;
  await for (final entity in support.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final directoryName = entity.path.split(Platform.pathSeparator).last;
    if (!directoryName.startsWith(_privateUsdPrefix)) continue;
    try {
      await entity.delete(recursive: true);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Removes the device-wide token stores and their temporary files, for a
/// full reset. The Keystore attestation key stays. Attempts every file and
/// then rethrows the first failure.
Future<void> deletePrivateUsdTokenStores() async {
  final support = await getWalletSupportDirectory();
  Object? firstError;
  StackTrace? firstStackTrace;
  await for (final entity in support.list(followLinks: false)) {
    if (entity is! File) continue;
    final fileName = entity.path.split(Platform.pathSeparator).last;
    if (!fileName.startsWith(_privateUsdTokenStorePrefix)) continue;
    try {
      await entity.delete();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
