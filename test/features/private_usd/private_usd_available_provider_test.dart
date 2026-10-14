import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';

// Plan reference §8.3: the define, a mobile Android build, a deployment, the
// kill switch not off, and a software account with a ZIP-32 index.
void main() {
  const software = AccountInfo(
    uuid: 'software',
    name: 'Main',
    order: 0,
    zip32AccountIndex: 0,
  );

  bool available({
    bool enabled = true,
    AppFormFactor formFactor = AppFormFactor.mobile,
    TargetPlatform platform = TargetPlatform.android,
    bool hasDeployment = true,
    bool killSwitchAvailable = true,
    AccountInfo? activeAccount = software,
  }) => privateUsdAvailableFor(
    enabled: enabled,
    formFactor: formFactor,
    platform: platform,
    hasDeployment: hasDeployment,
    killSwitchAvailable: killSwitchAvailable,
    activeAccount: activeAccount,
  );

  test('a software account on a mobile Android build with a deployment', () {
    expect(available(), isTrue);
    expect(
      available(
        activeAccount: const AccountInfo(
          uuid: 'second',
          name: 'Second',
          order: 1,
          zip32AccountIndex: 3,
        ),
      ),
      isTrue,
    );
  });

  test('each missing condition hides it', () {
    final cases = <String, bool>{
      'define off': available(enabled: false),
      'desktop': available(formFactor: AppFormFactor.desktop),
      'iOS': available(platform: TargetPlatform.iOS),
      'no deployment (regtest)': available(hasDeployment: false),
      'kill switch off': available(killSwitchAvailable: false),
      'no active account': available(activeAccount: null),
      'Keystone': available(
        activeAccount: const AccountInfo(
          uuid: 'keystone',
          name: 'Keystone',
          order: 1,
          isHardware: true,
          hardwareSignerKind: HardwareSignerKind.keystone,
          zip32AccountIndex: 0,
        ),
      ),
      'Ledger': available(
        activeAccount: const AccountInfo(
          uuid: 'ledger',
          name: 'Ledger',
          order: 1,
          isHardware: true,
          hardwareSignerKind: HardwareSignerKind.ledger,
          zip32AccountIndex: 0,
        ),
      ),
      'no ZIP-32 index': available(
        activeAccount: const AccountInfo(
          uuid: 'imported',
          name: 'Imported',
          order: 1,
        ),
      ),
    };
    for (final entry in cases.entries) {
      expect(entry.value, isFalse, reason: entry.key);
    }
  });
}
