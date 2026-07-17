import 'dart:async';
import 'dart:collection';

import 'policy.dart';

/// Thrown when a [RateLimiter] rejects a call because its wait queue is
/// full.
final class RateLimitExceededException implements Exception {
  /// Creates an exception for a limiter whose queue is capped at
  /// [maxQueueLength].
  const RateLimitExceededException(this.maxQueueLength);

  /// The queue capacity that was exceeded.
  final int maxQueueLength;

  @override
  String toString() =>
      'RateLimitExceededException: no permits available and the wait queue '
      'is full (maxQueueLength: $maxQueueLength)';
}

/// Limits how often actions start, using a token bucket.
///
/// The bucket starts full with [maxPermits] tokens and refills at a steady
/// rate of [maxPermits] tokens per [per], one token every
/// `per / maxPermits`. Each call consumes one token before its action
/// starts. A full bucket allows a burst of up to [maxPermits] immediate
/// calls; after that, calls proceed at the refill rate.
///
/// When no token is available the call waits in a FIFO queue. If
/// [maxQueueLength] is set and the queue is full, the call fails with
/// [RateLimitExceededException] instead of waiting.
///
/// The token is consumed even if the action later fails; failures are not
/// refunded.
///
/// A limiter is stateful: create one instance per rate-limited resource and
/// share it between all callers of that resource.
///
/// The refill timer runs until the bucket is full again, up to [per] after
/// the most recent call, and keeps the isolate alive while it runs. Call
/// [dispose] to stop it earlier, for example between tests or on shutdown.
///
/// ```dart
/// final limiter = RateLimiter(maxPermits: 10, per: Duration(seconds: 1));
/// final result = await limiter.execute(() => callThirdPartyApi());
/// ```
final class RateLimiter implements Policy {
  /// Creates a token bucket rate limiter.
  ///
  /// [maxPermits] is both the bucket capacity and the number of tokens
  /// refilled per [per]; it must be at least 1. [per] must be positive and
  /// at least [maxPermits] microseconds long, so that the refill interval
  /// is measurable.
  ///
  /// [maxQueueLength] caps the wait queue. Null means the queue is
  /// unbounded. Zero means calls never wait: when no token is available
  /// they fail immediately with [RateLimitExceededException].
  RateLimiter({
    required this.maxPermits,
    required this.per,
    this.maxQueueLength,
  }) : _tokens = maxPermits {
    if (maxPermits < 1) {
      throw ArgumentError.value(maxPermits, 'maxPermits', 'must be at least 1');
    }
    if (per <= Duration.zero) {
      throw ArgumentError.value(per, 'per', 'must be positive');
    }
    if (per ~/ maxPermits == Duration.zero) {
      throw ArgumentError.value(
        per,
        'per',
        'must be at least maxPermits microseconds',
      );
    }
    final maxQueueLength = this.maxQueueLength;
    if (maxQueueLength != null && maxQueueLength < 0) {
      throw ArgumentError.value(
        maxQueueLength,
        'maxQueueLength',
        'must not be negative',
      );
    }
  }

  /// The bucket capacity and the number of tokens refilled per [per].
  final int maxPermits;

  /// The period over which [maxPermits] tokens are refilled.
  final Duration per;

  /// The maximum number of waiting calls, or null for an unbounded queue.
  final int? maxQueueLength;

  int _tokens;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  Timer? _refillTimer;
  bool _disposed = false;

  /// The number of calls currently waiting for a token.
  int get queueLength => _waiters.length;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    if (_disposed) {
      throw StateError('RateLimiter disposed');
    }
    await _acquire();
    return action();
  }

  /// Cancels the refill timer and fails all waiting calls.
  ///
  /// Waiting calls complete with a [StateError], and after disposal
  /// [execute] throws a [StateError] without running the action. Calling
  /// dispose again has no effect.
  ///
  /// Disposal is optional: without it the refill timer stops on its own
  /// once the bucket is full, at most [per] after the last call.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refillTimer?.cancel();
    _refillTimer = null;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(StateError('RateLimiter disposed'));
    }
  }

  Future<void> _acquire() {
    if (_waiters.isEmpty && _tokens > 0) {
      _tokens--;
      _ensureRefillTimer();
      return Future<void>.value();
    }
    final maxQueueLength = this.maxQueueLength;
    if (maxQueueLength != null && _waiters.length >= maxQueueLength) {
      throw RateLimitExceededException(maxQueueLength);
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    _ensureRefillTimer();
    return waiter.future;
  }

  void _ensureRefillTimer() {
    if (_refillTimer != null) {
      return;
    }
    if (_tokens >= maxPermits && _waiters.isEmpty) {
      return;
    }
    _refillTimer = Timer.periodic(per ~/ maxPermits, _onRefillTick);
  }

  void _onRefillTick(Timer timer) {
    if (_waiters.isNotEmpty) {
      // Hand the new token directly to the oldest waiter.
      _waiters.removeFirst().complete();
      return;
    }
    _tokens++;
    if (_tokens >= maxPermits) {
      timer.cancel();
      _refillTimer = null;
    }
  }
}
