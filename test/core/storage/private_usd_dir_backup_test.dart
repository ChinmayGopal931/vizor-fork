// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';

// iOS plan DI6 and invariant 25: the swap records' directory stays out of
// device backups, marked before anything is written in it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      kWalletDbNameKey: 'zcash_wallet_backup_test.db',
    });
    support = await Directory.systemTemp.createTemp('private-usd-backup-');
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(support.path);
    addTearDown(() async {
      PathProviderPlatform.instance = paths;
      await support.delete(recursive: true);
    });
  });

  test('the directory is marked when it is made, and once per process '
      'otherwise', () async {
    final marked = <String>[];
    Future<void> mark(String directory) async {
      expect(Directory(directory).existsSync(), isTrue);
      marked.add(directory);
    }

    final path = await getPrivateUsdDirPath('test', excludeFromBackup: mark);
    expect(marked, [path]);

    await getPrivateUsdDirPath('test', excludeFromBackup: mark);
    expect(marked, [path], reason: 'already marked in this process');

    // A reset deletes it; the mark went with it, so the next one is marked.
    await deletePrivateUsdDirectories();
    await getPrivateUsdDirPath('test', excludeFromBackup: mark);
    expect(marked, [path, path]);
  });

  test('a mark that fails is tried again, and never blocks the path', () async {
    var attempts = 0;
    Future<void> failing(String directory) async {
      attempts++;
      throw StateError('no mark');
    }

    final path = await getPrivateUsdDirPath('main', excludeFromBackup: failing);
    expect(Directory(path).existsSync(), isTrue);
    await getPrivateUsdDirPath('main', excludeFromBackup: failing);
    expect(attempts, 2);

    final marked = <String>[];
    await getPrivateUsdDirPath(
      'main',
      excludeFromBackup: (directory) async => marked.add(directory),
    );
    expect(marked, [path]);
  });
}

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}
