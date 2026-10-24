import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_activity_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_deposits_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_spend_status_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// Home, Activity and the Shielded USD screen build their rows from one
// activity, so each lists the account's sends and received sends too.
void main() {
  ProviderContainer container({required bool engine}) {
    final container = ProviderContainer(
      overrides: [
        privateUsdEngineEnabledProvider.overrideWithValue(engine),
        privateUsdCurrentDeploymentProvider.overrideWithValue(_sepolia),
        privateUsdActivityRecordsProvider(
          _account,
        ).overrideWith((ref) => const []),
        privateUsdReverseActivityRecordsProvider(
          _account,
        ).overrideWith((ref) => const []),
        privateUsdDepositRecordsProvider(
          _account,
        ).overrideWith((ref) => const []),
        privateUsdSendRecordsProvider(
          _account,
        ).overrideWith(() => _Sends(_account, engine)),
        privateUsdBalanceProvider(
          _account,
        ).overrideWith(() => _Balance(_account)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the activity carries the account\'s sends and received sends', () {
    final activity = container(
      engine: true,
    ).read(privateUsdActivityProvider(_account));

    expect(activity.sends, [previewPrivateUsdSendRecord()]);
    expect(activity.receipts, [previewPrivateUsdReceipt()]);
  });

  test('without the engine it reads no balance', () {
    final engineless = container(engine: false);

    expect(
      engineless.read(privateUsdActivityProvider(_account)),
      same(PrivateUsdActivity.empty),
    );
    expect(engineless.exists(privateUsdBalanceProvider(_account)), isFalse);
  });
}

const _account = 'account';

class _Sends extends PrivateUsdSendRecordsNotifier {
  _Sends(super.accountUuid, this.engine);

  final bool engine;

  @override
  List<ApiSendRecord> build() =>
      engine ? [previewPrivateUsdSendRecord()] : const [];
}

class _Balance extends PrivateUsdBalanceNotifier {
  _Balance(super.accountUuid);

  @override
  PrivateUsdBalanceState build() => PrivateUsdBalanceState(
    received: <RailgunReceipt>[previewPrivateUsdReceipt()],
  );
}

const _dollars = '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c';

const _sepolia = ApiDeployment(
  network: 'testnet',
  railgunNetwork: 'sepolia',
  chainId: 11155111,
  token: _dollars,
  tokenDecimals: 6,
  keylessRpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  poiNodeUrl: 'https://ppoi.fdi.network/',
  railgunProxy: '0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea',
  relayAdapt: '0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D',
  relayerRailgunAddress: '0zk1relayer',
  allowedHosts: ['ethereum-sepolia-rpc.publicnode.com'],
  explorerTxPrefix: 'https://sepolia.etherscan.io/tx/',
  railscanTxPrefix: 'https://railscan.io/sepolia/tx/',
  zcashConfirmations: 2,
  escrowConfirmations: 2,
  screeningSeconds: 3600,
  maxRelayerFee: '2000000',
  usdTokens: [ApiUsdToken(address: _dollars, symbol: 'tUSD')],
  bridgeAvailable: true,
);
