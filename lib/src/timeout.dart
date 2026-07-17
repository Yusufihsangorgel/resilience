import 'dart:async';

import 'policy.dart';

/// Fails an action with a [TimeoutException] when it takes too long.
///
/// Dart futures cannot be cancelled. When the timeout fires, the underlying
/// action keeps running; only its eventual result or error is discarded.
/// A timeout bounds how long the caller waits, not how long the work runs.
/// If the action holds a scarce resource, combine this policy with a
/// `Bulkhead` or handle cleanup inside the action itself.
///
/// ```dart
/// const timeout = Timeout(Duration(seconds: 2));
/// final page = await timeout.execute(() => fetchPage(url));
/// ```
final class Timeout implements Policy {
  /// Creates a timeout policy that waits at most [duration].
  ///
  /// [duration] must be positive. Duration comparisons cannot run in a
  /// const constructor assert, so [execute] performs the check and throws
  /// an [ArgumentError] for a non-positive duration.
  const Timeout(this.duration);

  /// The maximum time to wait for the action to complete.
  final Duration duration;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'must be positive');
    }
    return action().timeout(duration);
  }
}
