import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/private_usd/services/railgun_host_channel.dart';

final privateUsdLifecycleProvider = Provider((ref) => PrivateUsdLifecycle());

/// The Private USD work an account deletion or a wallet reset drains first
/// (plan reference §8.4): the Railgun page from M3, the swap engine from M5.
/// Like the Gift Card fence, it holds even before any of that work exists,
/// so work built during a drain starts drained.
class PrivateUsdLifecycle {
  PrivateUsdLifecycle({RailgunHost host = const RailgunHostChannel()})
    : _host = host;

  final RailgunHost _host;
  final _owners = <Object, _Registration>{};
  bool _quiesced = false;
  final _pending = <Future<void>>[];

  bool get isQuiesced => _quiesced;

  /// [wipe] deletes the Railgun page's storage, for the owner that holds
  /// the page.
  void register({
    required Object owner,
    required Future<void> Function() quiesceAndDrain,
    required void Function() resume,
    Future<void> Function()? wipe,
  }) {
    _owners[owner] = _Registration(quiesceAndDrain, resume, wipe);
    if (_quiesced) _pending.add(quiesceAndDrain());
  }

  void unregister(Object owner) => _owners.remove(owner);

  /// Stops new work, closes the Railgun page and waits for running work.
  /// Pair with [resume], also when the destructive step fails.
  Future<void> quiesceAndDrain() async {
    _quiesced = true;
    await Future.wait([
      for (final registration in _owners.values.toList())
        registration.quiesceAndDrain(),
    ]);
    final pending = _pending.toList();
    _pending.clear();
    await Future.wait(pending);
  }

  void resume() {
    _quiesced = false;
    for (final registration in _owners.values.toList()) {
      registration.resume();
    }
  }

  /// For a full reset, once the wallet is deleted: closes the page and
  /// deletes everything the page origin stored, every account's Railgun
  /// wallet with it. Works with or without a Railgun engine in this run.
  Future<void> wipeRailgunPage() async {
    final wipes = [
      for (final registration in _owners.values) ?registration.wipe,
    ];
    if (wipes.isEmpty) {
      await _host.wipe();
      return;
    }
    for (final wipe in wipes) {
      await wipe();
    }
  }
}

class _Registration {
  const _Registration(this.quiesceAndDrain, this.resume, this.wipe);

  final Future<void> Function() quiesceAndDrain;
  final void Function() resume;
  final Future<void> Function()? wipe;
}
