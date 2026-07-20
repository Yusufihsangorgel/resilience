import 'backoff.dart';
import 'circuit_breaker.dart';
import 'policy.dart';

/// Details about a failed attempt that is about to be retried.
///
/// Passed to the `onRetry` callback of [Retry]. Not created for the final
/// failed attempt, which rethrows instead of retrying.
final class RetryEvent {
  /// Creates an event for failed attempt number [attempt].
  const RetryEvent({
    required this.attempt,
    required this.error,
    required this.stackTrace,
    required this.nextDelay,
  });

  /// The 1-based number of the attempt that failed.
  final int attempt;

  /// The error thrown by the failed attempt.
  final Object error;

  /// The stack trace of [error].
  final StackTrace stackTrace;

  /// The delay before the next attempt starts.
  final Duration nextDelay;

  @override
  String toString() =>
      'RetryEvent(attempt: $attempt, nextDelay: $nextDelay, error: $error)';
}

/// Retries a failed action up to a fixed number of attempts.
///
/// A `Retry` is stateless and can be shared between callers and reused for
/// any number of actions.
///
/// ```dart
/// final retry = Retry(
///   maxAttempts: 4,
///   backoff: Backoff.exponential(jitter: 0.5),
///   retryIf: (error) => error is TimeoutException,
/// );
/// final response = await retry.execute(() => fetchStatus());
/// ```
final class Retry implements Policy {
  /// Creates a retry policy.
  ///
  /// [maxAttempts] is the total number of attempts including the first one
  /// and must be at least 1. [backoff] computes the delay between attempts
  /// and defaults to no delay.
  ///
  /// [retryIf] decides whether an error is retried. When it returns false
  /// the error is rethrown immediately. When null, every error is retried
  /// except [CircuitOpenException].
  ///
  /// That exception is excluded because retrying it cannot help. A breaker
  /// throws it without calling the action at all, so a retry loop wrapped
  /// around a breaker would spend its whole budget, and sleep through every
  /// backoff delay, on calls that were never made — and hand the caller a
  /// [CircuitOpenException] instead of the failure that actually opened the
  /// circuit. Only time reopens a circuit. Supplying [retryIf] takes over
  /// completely, including this decision.
  ///
  /// [onRetry] is called before each delay with a [RetryEvent] describing
  /// the failed attempt. It is not called for the final failed attempt.
  /// The callback must not throw: an error thrown from it replaces the
  /// action's error and ends the retry loop.
  Retry({
    this.maxAttempts = 3,
    this.backoff = const Backoff.none(),
    bool Function(Object error)? retryIf,
    void Function(RetryEvent event)? onRetry,
  }) : _retryIf = retryIf,
       _onRetry = onRetry {
    if (maxAttempts < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'must be at least 1',
      );
    }
  }

  /// The total number of attempts, including the first one.
  final int maxAttempts;

  /// The strategy that computes the delay between attempts.
  final Backoff backoff;

  final bool Function(Object error)? _retryIf;
  final void Function(RetryEvent event)? _onRetry;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } catch (error, stackTrace) {
        final retryIf = _retryIf;
        final retryable = retryIf != null
            ? retryIf(error)
            : error is! CircuitOpenException;
        if (attempt >= maxAttempts || !retryable) {
          rethrow;
        }
        final nextDelay = backoff.delay(attempt);
        _onRetry?.call(
          RetryEvent(
            attempt: attempt,
            error: error,
            stackTrace: stackTrace,
            nextDelay: nextDelay,
          ),
        );
        if (nextDelay > Duration.zero) {
          await Future<void>.delayed(nextDelay);
        }
      }
    }
  }
}
