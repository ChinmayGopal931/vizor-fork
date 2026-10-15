import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_owner_auth.dart';

const kWalletResetDeviceAuthReason = 'Confirm reset Veylor';
const kWalletResetDeviceAuthRequiredMessage =
    'Device authentication is required to reset Veylor.';
const kWalletResetDeviceAuthFailedMessage =
    "Couldn't verify device ownership. Please try again.";
const kWalletResetFailedMessage = "Couldn't reset Veylor. Please try again.";

final deviceOwnerAuthProvider = Provider<DeviceOwnerAuth>(
  (ref) => DeviceOwnerAuth(),
);

Future<bool> verifyDeviceOwnerForWalletReset(WidgetRef ref) {
  return ref
      .read(deviceOwnerAuthProvider)
      .verify(reason: kWalletResetDeviceAuthReason);
}
