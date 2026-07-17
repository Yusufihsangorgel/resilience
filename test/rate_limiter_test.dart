import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

void main() {
  group('RateLimiter', () {
    test('allows an immediate burst of up to maxPermits calls', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 3,
          per: const Duration(milliseconds: 300),
        );
        var started = 0;
        for (var i = 0; i < 3; i++) {
          unawaited(limiter.execute(() async => started++));
        }
        async.flushMicrotasks();
        expect(started, 3);
      });
    });

    test('makes the next call wait for a refilled token', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 2,
          per: const Duration(milliseconds: 200),
        );
        var started = 0;
        for (var i = 0; i < 3; i++) {
          unawaited(limiter.execute(() async => started++));
        }
        async.flushMicrotasks();
        expect(started, 2);

        // One token refills every per / maxPermits = 100 ms.
        async.elapse(const Duration(milliseconds: 99));
        expect(started, 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(started, 3);
      });
    });

    test('serves waiting calls in FIFO order', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 1,
          per: const Duration(milliseconds: 100),
        );
        final order = <int>[];
        for (var i = 0; i < 4; i++) {
          unawaited(limiter.execute(() async => order.add(i)));
        }
        async.flushMicrotasks();
        expect(order, [0]);
        async.elapse(const Duration(milliseconds: 300));
        expect(order, [0, 1, 2, 3]);
      });
    });

    test('spreads queued calls at the refill rate', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 1,
          per: const Duration(milliseconds: 100),
        );
        final startTimes = <Duration>[];
        final epoch = async.elapsed;
        for (var i = 0; i < 3; i++) {
          unawaited(
            limiter.execute(() async {
              startTimes.add(async.elapsed - epoch);
            }),
          );
        }
        async.elapse(const Duration(milliseconds: 500));
        expect(startTimes, const [
          Duration.zero,
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
        ]);
      });
    });

    test('rejects calls when the wait queue is full', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 1,
          per: const Duration(milliseconds: 100),
          maxQueueLength: 1,
        );
        var started = 0;
        final errors = <Object>[];
        for (var i = 0; i < 3; i++) {
          unawaited(
            limiter.execute(() async => started++).then<void>(
                  (_) {},
                  onError: errors.add,
                ),
          );
        }
        async.flushMicrotasks();
        expect(started, 1);
        expect(errors, hasLength(1));
        expect(errors.single, isA<RateLimitExceededException>());
        expect(errors.single.toString(), contains('maxQueueLength: 1'));

        // The queued call still runs once a token refills.
        async.elapse(const Duration(milliseconds: 100));
        expect(started, 2);
      });
    });

    test('with maxQueueLength 0 rejects instead of waiting', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 1,
          per: const Duration(milliseconds: 100),
          maxQueueLength: 0,
        );
        Object? error;
        unawaited(limiter.execute(() async => 'first'));
        unawaited(
          limiter.execute(() async => 'second').then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          ),
        );
        async.flushMicrotasks();
        expect(error, isA<RateLimitExceededException>());
      });
    });

    test('does not refill beyond maxPermits while idle', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 2,
          per: const Duration(milliseconds: 200),
        );
        var started = 0;
        // Drain the bucket, then stay idle much longer than per.
        unawaited(limiter.execute(() async => started++));
        unawaited(limiter.execute(() async => started++));
        async.elapse(const Duration(seconds: 10));
        expect(started, 2);

        // Only a burst of maxPermits is available afterwards.
        for (var i = 0; i < 3; i++) {
          unawaited(limiter.execute(() async => started++));
        }
        async.flushMicrotasks();
        expect(started, 4);
        async.elapse(const Duration(milliseconds: 100));
        expect(started, 5);
      });
    });

    test('consumes the token even when the action fails', () {
      fakeAsync((async) {
        final limiter = RateLimiter(
          maxPermits: 1,
          per: const Duration(milliseconds: 100),
        );
        var started = 0;
        unawaited(
          limiter.execute<void>(() async {
            started++;
            throw const FormatException('boom');
          }).then<void>((_) {}, onError: (Object _) {}),
        );
        unawaited(limiter.execute(() async => started++));
        async.flushMicrotasks();
        expect(started, 1);
        async.elapse(const Duration(milliseconds: 100));
        expect(started, 2);
      });
    });

    test('rejects invalid arguments', () {
      expect(
        () => RateLimiter(maxPermits: 0, per: const Duration(seconds: 1)),
        throwsArgumentError,
      );
      expect(
        () => RateLimiter(maxPermits: 1, per: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => RateLimiter(
          maxPermits: 10,
          per: const Duration(microseconds: 5),
        ),
        throwsArgumentError,
      );
      expect(
        () => RateLimiter(
          maxPermits: 1,
          per: const Duration(seconds: 1),
          maxQueueLength: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
