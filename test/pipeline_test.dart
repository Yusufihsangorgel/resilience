import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

/// A policy that records when it is entered, for asserting wrap order.
class RecordingPolicy implements Policy {
  RecordingPolicy(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    log.add('$name:enter');
    try {
      return await action();
    } finally {
      log.add('$name:exit');
    }
  }
}

void main() {
  group('ResiliencePipeline', () {
    test('an empty pipeline runs the action unchanged', () async {
      final pipeline = ResiliencePipeline([]);
      expect(await pipeline.execute(() async => 'plain'), 'plain');
    });

    test(
      'wraps policies from the outside in, first policy outermost',
      () async {
        final log = <String>[];
        final pipeline = ResiliencePipeline([
          RecordingPolicy('outer', log),
          RecordingPolicy('middle', log),
          RecordingPolicy('inner', log),
        ]);
        await pipeline.execute(() async => log.add('action'));
        expect(log, [
          'outer:enter',
          'middle:enter',
          'inner:enter',
          'action',
          'inner:exit',
          'middle:exit',
          'outer:exit',
        ]);
      },
    );

    test(
      'a retry outside a circuit breaker stops when the breaker opens',
      () async {
        var calls = 0;
        final events = <RetryEvent>[];
        final breaker = CircuitBreaker(failureThreshold: 1);
        final pipeline = ResiliencePipeline([
          Retry(maxAttempts: 3, onRetry: events.add),
          breaker,
        ]);

        await expectLater(
          pipeline.execute<void>(() async {
            calls++;
            throw const FormatException('boom');
          }),
          throwsA(isA<CircuitOpenException>()),
        );

        // The first attempt failed and opened the breaker. The second was
        // rejected without reaching the action, and the retry stopped there
        // rather than spending its third attempt, and a backoff delay, on a
        // call that would also never be made. Only time reopens a circuit.
        expect(calls, 1);
        expect(breaker.state, CircuitState.open);
        expect(events, hasLength(1));
        expect(events.single.error, isFormatException);
      },
    );

    test('the README pipeline does not retry an open circuit', () {
      // Retry outside the breaker, Timeout inside it: the composition the
      // README shows. The first call opens the breaker on real failures.
      // The next call must fail fast on CircuitOpenException, without
      // sleeping the backoff or touching the action; only time reopens a
      // circuit. A retryIf that returned true for CircuitOpenException
      // would spend the whole budget here and defeat that quiet period.
      fakeAsync((async) {
        var calls = 0;
        final retried = <Object>[];
        final breaker = CircuitBreaker(
          failureThreshold: 3,
          resetTimeout: const Duration(seconds: 30),
        );
        final pipeline = ResiliencePipeline([
          Retry(
            maxAttempts: 3,
            backoff: const Backoff.fixed(Duration(milliseconds: 40)),
            onRetry: (event) => retried.add(event.error),
          ),
          breaker,
          const Timeout(Duration(milliseconds: 250)),
        ]);

        Future<Never> down() async {
          calls++;
          throw StateError('upstream down');
        }

        Object? firstError;
        unawaited(
          pipeline
              .execute<void>(down)
              .then<void>(
                (_) {},
                onError: (Object e) {
                  firstError = e;
                },
              ),
        );

        async.flushMicrotasks();
        expect(calls, 1);
        async.elapse(const Duration(milliseconds: 40));
        expect(calls, 2);
        async.elapse(const Duration(milliseconds: 40));
        expect(calls, 3);
        expect(firstError, isA<StateError>());
        expect(breaker.state, CircuitState.open);
        expect(retried, hasLength(2));
        expect(retried, everyElement(isA<StateError>()));

        Object? secondError;
        unawaited(
          pipeline
              .execute<void>(down)
              .then<void>(
                (_) {},
                onError: (Object e) {
                  secondError = e;
                },
              ),
        );
        async.flushMicrotasks();
        expect(secondError, isA<CircuitOpenException>());
        expect(calls, 3);
        expect(retried, hasLength(2));

        // Well past every backoff the retry would have slept if it had
        // treated CircuitOpenException as retryable. Still no extra work.
        async.elapse(const Duration(seconds: 5));
        expect(calls, 3);
        expect(retried, hasLength(2));
        expect(breaker.state, CircuitState.open);
      });
    });

    test('a circuit breaker outside a retry counts one exhausted retry as '
        'one failure', () async {
      var calls = 0;
      final breaker = CircuitBreaker(failureThreshold: 2);
      final pipeline = ResiliencePipeline([breaker, Retry(maxAttempts: 3)]);

      await expectLater(
        pipeline.execute<void>(() async {
          calls++;
          throw const FormatException('boom');
        }),
        throwsFormatException,
      );

      // Three attempts inside the retry, one counted failure outside it.
      expect(calls, 3);
      expect(breaker.state, CircuitState.closed);
    });

    test('a pipeline is itself a policy and can be nested', () async {
      final log = <String>[];
      final inner = ResiliencePipeline([RecordingPolicy('inner', log)]);
      final outer = ResiliencePipeline([RecordingPolicy('outer', log), inner]);
      expect(await outer.execute(() async => 7), 7);
      expect(log, ['outer:enter', 'inner:enter', 'inner:exit', 'outer:exit']);
    });

    test('does not reflect later mutations of the policy list', () async {
      final log = <String>[];
      final policies = <Policy>[RecordingPolicy('kept', log)];
      final pipeline = ResiliencePipeline(policies);
      policies.add(RecordingPolicy('added-later', log));
      await pipeline.execute(() async => 0);
      expect(log, ['kept:enter', 'kept:exit']);
    });
  });
}
