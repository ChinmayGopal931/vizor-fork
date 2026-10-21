import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';

import 'support/fake_private_usd_backend.dart';

// The foreground swap loop (plan reference §5.10). The first four are zapp's
// `SwapLoopTest` ★ cases (58, 77, 155, 186); the rest pin the lock and drain
// rules of the M5 pitfalls. Time is the widget tester's fake clock.
void main() {
  const account = 'account-1';
  const key = PrivateUsdRecordKey(
    accountUuid: account,
    direction: PrivateUsdDirection.forward,
    index: 7,
  );
  const retry = PrivateUsdEngineTiming.retry;
  const persisted = PrivateUsdEngineTiming.problemAfter;

  late FakePrivateUsdBackend backend;
  late bool allowed;
  late List<Uint8List> seeds;
  Completer<void>? seedGate;
  final engines = <PrivateUsdEngine>[];

  // Each test ends with its engines disposed, so no nap timer outlives it.
  void engineTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      engines.clear();
      try {
        await body(tester);
      } finally {
        for (final engine in engines) {
          await engine.dispose();
        }
        await tester.pump();
      }
    });
  }

  PrivateUsdEngine engineFor(WidgetTester tester) {
    allowed = true;
    seeds = [];
    final engine = PrivateUsdEngine(
      backend: backend,
      readMnemonic: (_) async {
        final gate = seedGate;
        if (gate != null) await gate.future;
        final seed = Uint8List.fromList(List.filled(32, 7));
        seeds.add(seed);
        return seed;
      },
      allowed: () => allowed,
      now: () => tester.binding.clock.now(),
    );
    engines.add(engine);
    return engine;
  }

  ApiPrivateUsdErrorCode? problem(PrivateUsdEngine engine) =>
      engine.conversions.value[key]?.problem;

  engineTest(
    'a failed step is tried again, says why only once it keeps failing, and '
    'not after one goes through',
    (tester) async {
      backend = FakePrivateUsdBackend(
        answers: [
          ...List.filled(5, failing(ApiPrivateUsdErrorCode.relayerUnreachable)),
          waiting,
        ],
      );
      final engine = engineFor(tester);

      engine.start();
      await tester.pump();
      expect(problem(engine), isNull);
      expect(backend.advances, 1);

      await tester.pump(persisted);
      expect(backend.advances, 5);
      expect(problem(engine), ApiPrivateUsdErrorCode.relayerUnreachable);

      await tester.pump(retry);
      expect(backend.advances, 6);
      expect(problem(engine), isNull);
      expect(engine.conversions.value[key]!.failingSince, isNull);
    },
  );

  // zapp asks through a notification after five minutes; vizor has none
  // (D9), so the problem on the conversion is the one ask: shown once, held
  // while the steps keep failing, and cleared by the first that goes through.
  engineTest(
    'failing for five minutes asks the user once, and a step that goes '
    'through lets them off',
    (tester) async {
      backend = FakePrivateUsdBackend(
        answers: [
          ...List.filled(
            25,
            failing(ApiPrivateUsdErrorCode.relayerUnreachable),
          ),
          waiting,
        ],
      );
      final engine = engineFor(tester);
      var asks = 0;
      ApiPrivateUsdErrorCode? shown;
      engine.conversions.addListener(() {
        final next = engine.conversions.value[key]?.problem;
        if (shown == null && next != null) asks++;
        shown = next;
      });

      engine.start();
      await tester.pump();
      await tester.pump(const Duration(minutes: 4, seconds: 50));
      expect(asks, 1);
      expect(problem(engine), ApiPrivateUsdErrorCode.relayerUnreachable);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(minutes: 1));
      expect(asks, 1);

      await tester.pump(const Duration(minutes: 2));
      expect(backend.advances, greaterThanOrEqualTo(26));
      expect(problem(engine), isNull);
      expect(asks, 1);
    },
  );

  engineTest('a nudge cuts a nap short', (tester) async {
    backend = FakePrivateUsdBackend(answers: [waiting, waiting]);
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();
    expect(backend.advances, 1);
    engine.nudge();
    await tester.pump();

    expect(backend.advances, 2);
  });

  engineTest('cancellation is never taken for a failed step', (tester) async {
    backend = FakePrivateUsdBackend(
      answers: [
        ...List.filled(6, throwing(ApiPrivateUsdErrorCode.cancelled)),
        waiting,
      ],
    );
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();
    await tester.pump(persisted + retry);
    expect(backend.advances, 6);
    expect(problem(engine), isNull);
    expect(engine.conversions.value[key]?.failingSince, isNull);

    // Anything else that stops a step is a failure, shown after a minute.
    backend = FakePrivateUsdBackend(
      answers: [(_) => throw StateError('a bug')],
    );
    final failing = engineFor(tester);
    failing.start();
    await tester.pump();
    await tester.pump(persisted);
    expect(problem(failing), ApiPrivateUsdErrorCode.other);
  });

  engineTest('a lock with a call in flight cancels it, drops its result, '
      'and uses no seed until unlock', (tester) async {
    backend = FakePrivateUsdBackend(
      answers: [failing(ApiPrivateUsdErrorCode.relayerUnreachable), waiting],
    )..advanceGate = Completer<void>();
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();
    expect(backend.advances, 1);
    final inFlight = backend.advancedOpIds.single;
    // The seed went to Rust and was zeroed right after.
    expect(seeds.single, everyElement(0));

    allowed = false;
    final paused = engine.pause(PrivateUsdPauseReason.lock);
    expect(backend.cancelled, [inFlight]);
    expect(backend.sessionClears, 1);
    backend.advanceGate!.complete();
    backend.advanceGate = null;
    await tester.pump();
    await paused;
    // The result that landed after the lock is dropped.
    expect(engine.conversions.value[key]!.failingSince, isNull);
    expect(engine.conversions.value[key]!.checkedAt, isNull);

    await tester.pump(const Duration(minutes: 2));
    expect(backend.advances, 1);
    expect(seeds, hasLength(1));

    allowed = true;
    engine.start(resuming: true);
    expect(engine.conversions.value[key]!.resuming, isTrue);
    await tester.pump();
    expect(backend.advances, 2);
    expect(engine.conversions.value[key]!.resuming, isFalse);
  });

  engineTest('a seed read that finishes after a lock never reaches Rust', (
    tester,
  ) async {
    backend = FakePrivateUsdBackend();
    final engine = engineFor(tester);
    seedGate = Completer<void>();
    addTearDown(() => seedGate = null);

    engine.start();
    await tester.pump();
    allowed = false;
    unawaited(engine.pause(PrivateUsdPauseReason.lock));
    seedGate!.complete();
    await tester.pump();

    expect(seeds.single, everyElement(0));
    expect(backend.secretsSeen, isEmpty);
    expect(backend.advances, 0);
  });

  engineTest('a drain refuses new calls, cancels the running step and '
      'waits for it; resuming starts the loop again', (tester) async {
    backend = FakePrivateUsdBackend()..advanceGate = Completer<void>();
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();
    final inFlight = backend.advancedOpIds.single;

    var drained = false;
    final drain = engine.quiesceAndDrain().then((_) => drained = true);
    await tester.pump();
    expect(backend.cancelled, [inFlight]);
    expect(drained, isFalse);
    await expectLater(
      engine.quote(account, units: 1000000),
      throwsA(isA<PrivateUsdEngineUnavailableException>()),
    );

    backend.advanceGate!.complete();
    backend.advanceGate = null;
    await tester.pump();
    await drain;
    expect(drained, isTrue);
    await tester.pump(const Duration(minutes: 1));
    expect(backend.advances, 1);

    engine.resumeAfterMutation();
    await tester.pump();
    expect(backend.advances, 2);
  });

  // A lock contract's record stays unfinished in Rust's store, which never
  // drives it: it is shown as such, and never nags.
  engineTest('a conversion of another deployment is never advanced, never '
      'shows a problem and is never picked up again', (tester) async {
    const reverseKey = PrivateUsdRecordKey(
      accountUuid: account,
      direction: PrivateUsdDirection.reverse,
      index: 9,
    );
    backend = FakePrivateUsdBackend(
      records: {
        account: [forwardRecord(otherDeployment: true)],
      },
    );
    backend.reverse[account] = [
      previewPrivateUsdReverseRecord(
        index: 9,
        phase: ApiReversePhase.awaitingReady,
        otherDeployment: true,
      ),
    ];
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();
    await tester.pump(persisted + retry);
    engine.start(resuming: true);
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));

    expect(backend.advances, 0);
    expect(backend.reverseAdvances, 0);
    expect(seeds, isEmpty, reason: 'a seed was read for a record never driven');
    final forward = engine.conversions.value[key]!;
    final reverse = engine.reverseConversions.value[reverseKey]!;
    for (final status in <PrivateUsdStepStatus<Object?, Object?>>[
      forward,
      reverse,
    ]) {
      expect(status.otherDeployment, isTrue);
      expect(status.isUnderWay, isTrue);
      expect(status.isDriven, isFalse);
      expect(status.problem, isNull);
      expect(status.failingSince, isNull);
      expect(status.resuming, isFalse);
    }
  });

  engineTest('a conversion of another deployment holds up no new one', (
    tester,
  ) async {
    backend = FakePrivateUsdBackend(
      records: {
        account: [forwardRecord(otherDeployment: true)],
      },
    );
    backend.reverse[account] = [
      previewPrivateUsdReverseRecord(
        index: 9,
        phase: ApiReversePhase.awaitingReady,
        otherDeployment: true,
      ),
    ];
    final engine = engineFor(tester);

    expect(await privateUsdFindUnderWay(engine, account), isNull);

    backend.reverse[account]!.add(
      previewPrivateUsdReverseRecord(
        index: 10,
        phase: ApiReversePhase.awaitingReady,
      ),
    );
    final underWay = await privateUsdFindUnderWay(engine, account);
    expect(underWay?.direction, PrivateUsdDirection.reverse);
    expect(underWay?.index, 10);
  });

  engineTest('every account with a conversion under way is advanced (D14)', (
    tester,
  ) async {
    backend = FakePrivateUsdBackend(
      records: {
        'account-1': [forwardRecord(index: 3)],
        'account-2': [forwardRecord(index: 5)],
        'account-3': [forwardRecord(index: 9, outcome: ApiForwardOutcome.paid)],
      },
    );
    final engine = engineFor(tester);

    engine.start();
    await tester.pump();

    expect(backend.advances, 2);
    expect(
      engine.conversions.value.entries
          .where((entry) => entry.value.isUnderWay)
          .map((entry) => entry.key.accountUuid),
      unorderedEquals(['account-1', 'account-2']),
    );
  });
}
