import 'dart:async';
import 'dart:collection';

import 'policy.dart';

/// Thrown when a [Bulkhead] rejects a call because both the concurrency
/// slots and the queue are full.
final class BulkheadRejectedException implements Exception {
  /// Creates an exception for a bulkhead with the given limits.
  const BulkheadRejectedException({
    required this.maxConcurrent,
    required this.maxQueued,
  });

  /// The number of concurrency slots that were all busy.
  final int maxConcurrent;

  /// The queue capacity that was exceeded.
  final int maxQueued;

  @override
  String toString() =>
      'BulkheadRejectedException: all $maxConcurrent slots are busy and the '
      'queue is full (maxQueued: $maxQueued)';
}

/// Limits how many actions run at the same time.
///
/// At most [maxConcurrent] actions run concurrently. Excess calls wait in a
/// FIFO queue of at most [maxQueued] entries; beyond that, calls fail with
/// [BulkheadRejectedException]. With the default `maxQueued: 0` a saturated
/// bulkhead rejects immediately.
///
/// A bulkhead isolates a resource so that a slow dependency saturates its
/// own slots instead of every caller in the process.
///
/// A bulkhead is stateful: create one instance per protected resource and
/// share it between all callers of that resource.
///
/// ```dart
/// final bulkhead = Bulkhead(maxConcurrent: 4, maxQueued: 16);
/// final report = await bulkhead.execute(() => renderReport(id));
/// ```
final class Bulkhead implements Policy {
  /// Creates a bulkhead.
  ///
  /// [maxConcurrent] must be at least 1 and [maxQueued] must not be
  /// negative.
  Bulkhead({required this.maxConcurrent, this.maxQueued = 0}) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'must be at least 1',
      );
    }
    if (maxQueued < 0) {
      throw ArgumentError.value(maxQueued, 'maxQueued', 'must not be negative');
    }
  }

  /// The maximum number of actions running at the same time.
  final int maxConcurrent;

  /// The maximum number of waiting calls.
  final int maxQueued;

  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// The number of actions currently running.
  int get activeCount => _active;

  /// The number of calls currently waiting for a slot.
  int get queueLength => _waiters.length;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    if (_waiters.isEmpty && _active < maxConcurrent) {
      _active++;
    } else {
      if (_waiters.length >= maxQueued) {
        throw BulkheadRejectedException(
          maxConcurrent: maxConcurrent,
          maxQueued: maxQueued,
        );
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      // The slot is transferred to this waiter before it is completed, so
      // _active is not incremented again here.
      await waiter.future;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        // Hand the slot to the oldest waiter synchronously so a new call
        // cannot overtake it.
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}
