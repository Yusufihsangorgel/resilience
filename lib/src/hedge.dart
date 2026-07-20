import 'dart:async';

import 'policy.dart';

/// Sends a second copy of a slow call instead of waiting for it.
///
/// A small share of requests to a healthy backend are far slower than the
/// rest: a stalled connection, an unlucky GC pause, a node about to be
/// rescheduled. Retrying does not help, because a retry only starts after the
/// slow attempt has failed or timed out, by which point the latency is already
/// spent. Hedging starts another attempt while the first is still in flight and
/// takes whichever finishes first, which cuts the tail without waiting for
/// anything to fail.
///
/// ```dart
/// final hedge = Hedge(delay: Duration(milliseconds: 200));
/// final response = await hedge.execute(() => client.get(url));
/// ```
///
/// The first attempt starts immediately. If it has not finished [delay] later,
/// a second starts alongside it, and so on up to [maxAttempts]. When an attempt
/// fails, the next one starts at once rather than waiting out the delay, since
/// there is nothing left to wait for. The first success wins and the losers are
/// ignored; Dart cannot cancel a future, so they run to completion with their
/// results discarded. If every attempt fails, the last error is thrown.
///
/// Only hedge calls that are safe to run twice. A hedged POST that creates an
/// order can create two, so put this around reads, or around writes an
/// idempotency key makes safe. It also multiplies load on a backend that is
/// slow because it is overloaded, which is why [maxAttempts] is small by
/// default and [delay] should sit near your p95 rather than your median.
final class Hedge implements Policy {
  /// Creates a hedging policy.
  ///
  /// [delay] is how long to wait for an in-flight attempt before starting
  /// another. [maxAttempts] caps how many run in total, including the first.
  ///
  /// Throws [ArgumentError] if [delay] is negative or [maxAttempts] is below 1.
  Hedge({required this.delay, this.maxAttempts = 2}) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be at least 1');
    }
  }

  /// How long an attempt may run before another is started alongside it.
  final Duration delay;

  /// The total number of attempts allowed, including the first.
  final int maxAttempts;

  @override
  Future<T> execute<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    var started = 0;
    var settled = 0;
    Object? lastError;
    StackTrace? lastStackTrace;
    Timer? timer;
    // Declared up front so the two helpers can call each other.
    late void Function() scheduleNext;

    void startAttempt() {
      if (completer.isCompleted || started >= maxAttempts) return;
      started++;
      action().then(
        (value) {
          settled++;
          if (completer.isCompleted) return;
          timer?.cancel();
          completer.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          settled++;
          lastError = error;
          lastStackTrace = stackTrace;
          if (completer.isCompleted) return;
          if (started < maxAttempts) {
            // Nothing to wait for on this attempt any more, so bring the next
            // one forward instead of sitting out the rest of the delay.
            timer?.cancel();
            startAttempt();
            scheduleNext();
          } else if (settled == started) {
            // Every attempt that will ever run has now failed.
            timer?.cancel();
            completer.completeError(lastError!, lastStackTrace);
          }
        },
      );
    }

    scheduleNext = () {
      if (started >= maxAttempts) return;
      timer = Timer(delay, () {
        startAttempt();
        scheduleNext();
      });
    };

    startAttempt();
    scheduleNext();
    return completer.future;
  }
}
