import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

void main() {
  group('Retry', () {
    test('returns the result of a first successful attempt', () async {
      var calls = 0;
      final retry = Retry();
      final result = await retry.execute(() async {
        calls++;
        return 'ok';
      });
      expect(result, 'ok');
      expect(calls, 1);
    });

    test('retries until the action succeeds', () async {
      var calls = 0;
      final retry = Retry(maxAttempts: 5);
      final result = await retry.execute(() async {
        calls++;
        if (calls < 3) {
          throw const FormatException('not yet');
        }
        return calls;
      });
      expect(result, 3);
      expect(calls, 3);
    });

    test('rethrows the last error after maxAttempts attempts', () async {
      var calls = 0;
      final retry = Retry(maxAttempts: 3);
      await expectLater(
        retry.execute<void>(() async {
          calls++;
          throw StateError('attempt $calls');
        }),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'attempt 3'),
        ),
      );
      expect(calls, 3);
    });

    test('does not retry when retryIf returns false', () async {
      var calls = 0;
      final retry = Retry(retryIf: (error) => error is FormatException);
      await expectLater(
        retry.execute<void>(() async {
          calls++;
          throw StateError('fatal');
        }),
        throwsStateError,
      );
      expect(calls, 1);
    });

    test('retries only errors matched by retryIf', () async {
      var calls = 0;
      final retry = Retry(
        maxAttempts: 5,
        retryIf: (error) => error is FormatException,
      );
      await expectLater(
        retry.execute<void>(() async {
          calls++;
          if (calls == 1) {
            throw const FormatException('transient');
          }
          throw StateError('fatal');
        }),
        throwsStateError,
      );
      // The FormatException was retried, the StateError was not.
      expect(calls, 2);
    });

    test('reports each retried attempt to onRetry', () async {
      final events = <RetryEvent>[];
      final retry = Retry(
        maxAttempts: 3,
        backoff: const Backoff.fixed(Duration.zero),
        onRetry: events.add,
      );
      await expectLater(
        retry.execute<void>(() async => throw const FormatException('boom')),
        throwsFormatException,
      );
      // Two retries for three attempts; the final failure is not reported.
      expect(events, hasLength(2));
      expect(events[0].attempt, 1);
      expect(events[1].attempt, 2);
      expect(events[0].error, isFormatException);
      expect(events[0].stackTrace.toString(), isNotEmpty);
      expect(events[0].nextDelay, Duration.zero);
      expect(events[0].toString(), contains('attempt: 1'));
    });

    test('waits exactly the backoff delays between attempts', () {
      fakeAsync((async) {
        var calls = 0;
        Object? result;
        final retry = Retry(
          maxAttempts: 3,
          backoff: Backoff.exponential(
            initial: const Duration(milliseconds: 200),
          ),
        );
        unawaited(
          retry
              .execute(() async {
                calls++;
                if (calls < 3) {
                  throw const FormatException('not yet');
                }
                return 'done';
              })
              .then((value) => result = value),
        );

        async.flushMicrotasks();
        expect(calls, 1);

        // First delay is 200 ms; nothing happens one tick early.
        async.elapse(const Duration(milliseconds: 199));
        expect(calls, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 2);

        // Second delay is 400 ms.
        async.elapse(const Duration(milliseconds: 399));
        expect(calls, 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 3);
        expect(result, 'done');
      });
    });

    test('passes the failed attempt number to the backoff', () {
      fakeAsync((async) {
        final requestedAttempts = <int>[];
        final retry = Retry(
          maxAttempts: 4,
          backoff: _RecordingBackoff(requestedAttempts),
        );
        unawaited(
          retry
              .execute<void>(() async => throw const FormatException('boom'))
              .catchError((Object _) {}),
        );
        async.elapse(const Duration(seconds: 1));
        expect(requestedAttempts, [1, 2, 3]);
      });
    });

    test('rejects maxAttempts below 1', () {
      expect(() => Retry(maxAttempts: 0), throwsArgumentError);
    });
  });
}

class _RecordingBackoff implements Backoff {
  _RecordingBackoff(this.requestedAttempts);

  final List<int> requestedAttempts;

  @override
  Duration delay(int attempt) {
    requestedAttempts.add(attempt);
    return const Duration(milliseconds: 1);
  }
}
