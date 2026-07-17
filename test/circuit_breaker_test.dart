import 'dart:async';

import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

/// A manually advanced clock for driving [CircuitBreaker.resetTimeout].
class FakeClock {
  DateTime current = DateTime(2026, 1, 1);

  DateTime call() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}

Future<Never> _fail() async => throw const FormatException('boom');

void main() {
  group('CircuitBreaker', () {
    late FakeClock clock;

    setUp(() {
      clock = FakeClock();
    });

    test('passes results through while closed', () async {
      final breaker = CircuitBreaker(now: clock.call);
      expect(await breaker.execute(() async => 42), 42);
      expect(breaker.state, CircuitState.closed);
    });

    test('opens after failureThreshold consecutive failures', () async {
      final states = <CircuitState>[];
      final breaker = CircuitBreaker(
        failureThreshold: 3,
        onStateChange: states.add,
        now: clock.call,
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(breaker.execute(_fail), throwsFormatException);
      }
      expect(breaker.state, CircuitState.open);
      expect(states, [CircuitState.open]);
    });

    test('rejects calls without running the action while open', () async {
      final breaker = CircuitBreaker(failureThreshold: 1, now: clock.call);
      await expectLater(breaker.execute(_fail), throwsFormatException);

      var calls = 0;
      await expectLater(
        breaker.execute(() async => calls++),
        throwsA(isA<CircuitOpenException>()),
      );
      expect(calls, 0);
    });

    test('reports the remaining open time in CircuitOpenException', () async {
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetTimeout: const Duration(seconds: 30),
        now: clock.call,
      );
      await expectLater(breaker.execute(_fail), throwsFormatException);

      clock.advance(const Duration(seconds: 10));
      await expectLater(
        breaker.execute(() async => 1),
        throwsA(
          isA<CircuitOpenException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 20),
          ),
        ),
      );
      expect(
        const CircuitOpenException(Duration(seconds: 20)).toString(),
        contains('0:00:20'),
      );
    });

    test('a success in between resets the consecutive failure count', () async {
      final breaker = CircuitBreaker(failureThreshold: 3, now: clock.call);
      for (var i = 0; i < 2; i++) {
        await expectLater(breaker.execute(_fail), throwsFormatException);
      }
      await breaker.execute(() async => 'ok');
      for (var i = 0; i < 2; i++) {
        await expectLater(breaker.execute(_fail), throwsFormatException);
      }
      // Two failures, a success, then two failures: never three in a row.
      expect(breaker.state, CircuitState.closed);
    });

    test('closes again after a successful half-open trial', () async {
      final states = <CircuitState>[];
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetTimeout: const Duration(seconds: 30),
        onStateChange: states.add,
        now: clock.call,
      );
      await expectLater(breaker.execute(_fail), throwsFormatException);

      clock.advance(const Duration(seconds: 31));
      expect(await breaker.execute(() async => 'recovered'), 'recovered');
      expect(breaker.state, CircuitState.closed);
      expect(states, [
        CircuitState.open,
        CircuitState.halfOpen,
        CircuitState.closed,
      ]);
    });

    test('reopens after a failed half-open trial', () async {
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetTimeout: const Duration(seconds: 30),
        now: clock.call,
      );
      await expectLater(breaker.execute(_fail), throwsFormatException);

      clock.advance(const Duration(seconds: 31));
      await expectLater(breaker.execute(_fail), throwsFormatException);
      expect(breaker.state, CircuitState.open);

      // The reset timeout restarts from the failed trial.
      clock.advance(const Duration(seconds: 29));
      await expectLater(
        breaker.execute(() async => 1),
        throwsA(isA<CircuitOpenException>()),
      );
      clock.advance(const Duration(seconds: 2));
      expect(await breaker.execute(() async => 'ok'), 'ok');
    });

    test(
      'allows exactly one trial when concurrent calls hit half-open',
      () async {
        final breaker = CircuitBreaker(
          failureThreshold: 1,
          resetTimeout: const Duration(seconds: 30),
          now: clock.call,
        );
        await expectLater(breaker.execute(_fail), throwsFormatException);
        clock.advance(const Duration(seconds: 31));

        final trialGate = Completer<String>();
        var started = 0;
        final futures = List.generate(5, (_) {
          return breaker.execute(() {
            started++;
            return trialGate.future;
          });
        });

        trialGate.complete('ok');
        final outcomes = await Future.wait(
          futures.map(
            (future) => future.then<Object>(
              (value) => value,
              onError: (Object error) => error,
            ),
          ),
        );

        expect(started, 1);
        expect(outcomes.where((o) => o == 'ok'), hasLength(1));
        expect(outcomes.whereType<CircuitOpenException>(), hasLength(4));
        expect(
          outcomes.whereType<CircuitOpenException>().map((e) => e.retryAfter),
          everyElement(Duration.zero),
        );
        expect(breaker.state, CircuitState.closed);
      },
    );

    test('does not count errors for which countAs returns false', () async {
      final breaker = CircuitBreaker(
        failureThreshold: 2,
        countAs: (error) => error is! StateError,
        now: clock.call,
      );
      for (var i = 0; i < 5; i++) {
        await expectLater(
          breaker.execute(() async => throw StateError('not counted')),
          throwsStateError,
        );
      }
      expect(breaker.state, CircuitState.closed);

      // Counted errors still open the breaker.
      await expectLater(breaker.execute(_fail), throwsFormatException);
      await expectLater(breaker.execute(_fail), throwsFormatException);
      expect(breaker.state, CircuitState.open);
    });

    test('keeps half-open after an uncounted trial failure', () async {
      final breaker = CircuitBreaker(
        failureThreshold: 1,
        resetTimeout: const Duration(seconds: 30),
        countAs: (error) => error is! StateError,
        now: clock.call,
      );
      await expectLater(breaker.execute(_fail), throwsFormatException);
      clock.advance(const Duration(seconds: 31));

      await expectLater(
        breaker.execute(() async => throw StateError('not counted')),
        throwsStateError,
      );
      expect(breaker.state, CircuitState.halfOpen);

      // The next call gets a fresh trial without waiting.
      expect(await breaker.execute(() async => 'ok'), 'ok');
      expect(breaker.state, CircuitState.closed);
    });

    test('rejects invalid arguments', () {
      expect(() => CircuitBreaker(failureThreshold: 0), throwsArgumentError);
      expect(
        () => CircuitBreaker(resetTimeout: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
