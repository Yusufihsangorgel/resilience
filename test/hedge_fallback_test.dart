import 'dart:async';

import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

/// An action whose attempts are completed by the test, so the timing is
/// decided here rather than by a stopwatch.
class ControlledAction {
  final List<Completer<String>> attempts = [];

  Future<String> call() {
    final completer = Completer<String>();
    attempts.add(completer);
    return completer.future;
  }

  int get started => attempts.length;
}

/// A policy that runs the action unchanged, for composing in tests.
class PassThrough implements Policy {
  @override
  Future<T> execute<T>(Future<T> Function() action) => action();
}

void main() {
  group('Hedge', () {
    test('a fast first attempt is never hedged', () async {
      final action = ControlledAction();
      final hedge = Hedge(delay: const Duration(milliseconds: 50));
      final result = hedge.execute(action.call);

      action.attempts.first.complete('fast');
      expect(await result, 'fast');

      // Well past the delay, and still only the one attempt.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(action.started, 1);
    });

    test(
      'a slow first attempt gets a second, and the second can win',
      () async {
        final action = ControlledAction();
        final hedge = Hedge(delay: const Duration(milliseconds: 30));
        final result = hedge.execute(action.call);

        expect(action.started, 1);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(action.started, 2, reason: 'the delay should have hedged it');

        action.attempts[1].complete('hedged');
        expect(await result, 'hedged');
      },
    );

    test('the original still wins if it finishes first', () async {
      final action = ControlledAction();
      final hedge = Hedge(delay: const Duration(milliseconds: 20));
      final result = hedge.execute(action.call);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(action.started, 2);

      action.attempts.first.complete('original');
      expect(await result, 'original');
      // The loser completing later must not disturb anything.
      action.attempts[1].complete('late');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('a failed attempt brings the next one forward', () async {
      final action = ControlledAction();
      final hedge = Hedge(delay: const Duration(seconds: 10));
      final result = hedge.execute(action.call);

      expect(action.started, 1);
      action.attempts.first.completeError(StateError('down'));
      // The ten second delay is irrelevant now: nothing is in flight to wait
      // for, so the next attempt should start immediately.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(action.started, 2);

      action.attempts[1].complete('second');
      expect(await result, 'second');
    });

    test('when every attempt fails the last error is thrown', () async {
      final action = ControlledAction();
      final hedge = Hedge(
        delay: const Duration(milliseconds: 5),
        maxAttempts: 2,
      );
      final result = hedge.execute(action.call);

      action.attempts.first.completeError(StateError('first'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(action.started, 2);
      action.attempts[1].completeError(StateError('second'));

      await expectLater(
        result,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'second'),
        ),
      );
    });

    test(
      'an action that throws synchronously errors the future, not the zone',
      () async {
        // A closed client throws before it returns a future. Every attempt does
        // it here, so the whole hedge must complete with that error rather than
        // letting the throw escape a Timer callback as an unhandled zone error
        // and leaving the caller to await forever.
        final hedge = Hedge(
          delay: const Duration(milliseconds: 5),
          maxAttempts: 3,
        );
        var attempts = 0;

        final zoneErrors = <Object>[];
        await runZonedGuarded(() async {
          await expectLater(
            hedge.execute<int>(() {
              attempts++;
              throw StateError('closed');
            }),
            throwsA(isA<StateError>()),
          );
        }, (error, stack) => zoneErrors.add(error));

        expect(attempts, 3, reason: 'every attempt should have run');
        expect(
          zoneErrors,
          isEmpty,
          reason: 'nothing should escape to the zone',
        );
      },
    );

    test(
      'a hedged attempt that throws synchronously does not hang the hedge',
      () async {
        // First attempt is slow and fails; the hedged one throws synchronously.
        final hedge = Hedge(
          delay: const Duration(milliseconds: 5),
          maxAttempts: 2,
        );
        var call = 0;

        final zoneErrors = <Object>[];
        await runZonedGuarded(() async {
          await expectLater(
            hedge
                .execute<int>(() {
                  call++;
                  if (call == 1) {
                    return Future<int>.delayed(
                      const Duration(milliseconds: 30),
                    ).then((_) => throw StateError('slow-fail'));
                  }
                  throw StateError('sync-hedge');
                })
                .timeout(const Duration(seconds: 1)),
            throwsA(isA<StateError>()),
          );
        }, (error, stack) => zoneErrors.add(error));

        expect(zoneErrors, isEmpty);
      },
    );

    test(
      'a slow attempt still failing after the hedge does not end it early',
      () async {
        final action = ControlledAction();
        final hedge = Hedge(delay: const Duration(milliseconds: 20));
        final result = hedge.execute(action.call);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(action.started, 2);

        // The hedge fails; the original is still running, so nothing is decided.
        action.attempts[1].completeError(StateError('hedge failed'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        action.attempts.first.complete('original recovered');
        expect(await result, 'original recovered');
      },
    );

    test('maxAttempts caps how many run', () async {
      final action = ControlledAction();
      final hedge = Hedge(
        delay: const Duration(milliseconds: 10),
        maxAttempts: 3,
      );
      final result = hedge.execute(action.call);

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(action.started, 3);

      action.attempts.last.complete('third');
      expect(await result, 'third');
    });

    test('bad arguments are rejected', () {
      expect(
        () => Hedge(delay: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => Hedge(delay: Duration.zero, maxAttempts: 0),
        throwsArgumentError,
      );
    });

    test('composes inside a pipeline', () async {
      final pipeline = ResiliencePipeline([
        Hedge(delay: const Duration(milliseconds: 10)),
        Timeout(const Duration(seconds: 5)),
      ]);
      expect(await pipeline.execute(() async => 'ok'), 'ok');
    });
  });

  group('withFallback', () {
    test('passes the value through when the action succeeds', () async {
      final value = await withFallback(
        PassThrough(),
        () async => 'live',
        fallback: (_, _) => 'cached',
      );
      expect(value, 'live');
    });

    test('substitutes when the policy gives up', () async {
      final value = await withFallback(
        Retry(maxAttempts: 2, backoff: Backoff.none()),
        () async => throw StateError('backend down'),
        fallback: (error, _) =>
            'cached after: ${(error as StateError).message}',
      );
      expect(value, 'cached after: backend down');
    });

    test('shouldHandle lets chosen errors through', () async {
      Future<String> run(Object error) => withFallback(
        PassThrough(),
        () async => throw error,
        fallback: (_, _) => 'cached',
        shouldHandle: (e) => e is! ArgumentError,
      );

      expect(await run(StateError('transient')), 'cached');
      await expectLater(run(ArgumentError('bad input')), throwsArgumentError);
    });

    test('an async fallback is awaited', () async {
      final value = await withFallback(
        PassThrough(),
        () async => throw StateError('down'),
        fallback: (_, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 'from disk';
        },
      );
      expect(value, 'from disk');
    });

    test('an error from the fallback propagates', () async {
      await expectLater(
        withFallback<String>(
          PassThrough(),
          () async => throw StateError('down'),
          fallback: (_, _) => throw StateError('cache empty too'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'cache empty too',
          ),
        ),
      );
    });

    test('the fallback receives the error and stack trace', () async {
      StackTrace? seen;
      await withFallback(
        PassThrough(),
        () async => throw StateError('down'),
        fallback: (error, stackTrace) {
          seen = stackTrace;
          return 'x';
        },
      );
      expect(seen, isNotNull);
    });

    test('wraps a whole pipeline, which is the intended shape', () async {
      final pipeline = ResiliencePipeline([
        Retry(maxAttempts: 2, backoff: Backoff.none()),
        Timeout(const Duration(seconds: 1)),
      ]);
      var calls = 0;
      final value = await withFallback(pipeline, () async {
        calls++;
        throw StateError('always down');
      }, fallback: (_, _) => 'degraded');
      expect(value, 'degraded');
      // The retry ran fully before the fallback stepped in, which is the whole
      // reason it sits outside rather than inside.
      expect(calls, 2);
    });
  });
}
