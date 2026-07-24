import 'policy.dart';

/// The state of a [CircuitBreaker].
enum CircuitState {
  /// Calls pass through. Consecutive failures are counted.
  closed,

  /// Calls fail fast with [CircuitOpenException] until the reset timeout
  /// elapses.
  open,

  /// One trial call is allowed through to probe whether the underlying
  /// resource has recovered.
  halfOpen,
}

/// Thrown when a [CircuitBreaker] rejects a call without running it.
final class CircuitOpenException implements Exception {
  /// Creates an exception with the time remaining until the next trial.
  const CircuitOpenException(this.retryAfter);

  /// How long until the breaker allows a trial call.
  ///
  /// [Duration.zero] means a half-open trial is already in flight and the
  /// breaker may accept a new call as soon as that trial settles.
  final Duration retryAfter;

  @override
  String toString() =>
      'CircuitOpenException: circuit is open, retry after $retryAfter';
}

/// Fails fast when an action keeps failing, giving the underlying resource
/// time to recover.
///
/// A breaker is stateful: create one instance per protected resource and
/// share it between all callers of that resource.
///
/// State machine:
///
/// * `closed`: calls pass through. After [failureThreshold] consecutive
///   counted failures the breaker opens. A success resets the count.
/// * `open`: calls throw [CircuitOpenException] without running the action.
///   After [resetTimeout] the next call transitions the breaker to
///   half-open. The transition happens lazily on that call; no timer runs
///   in the background.
/// * `halfOpen`: exactly one trial call runs. Concurrent calls throw
///   [CircuitOpenException] while the trial is in flight. A successful
///   trial closes the breaker; a counted failure reopens it.
///
/// A half-open trial that never settles keeps the breaker half-open and
/// rejecting every other call indefinitely. Wrap the action in a `Timeout`
/// inside the breaker so the trial always settles, as in the package
/// example.
///
/// The reset timeout is measured monotonically, with a [Stopwatch], so a system
/// clock change cannot shorten or extend the open period. Supplying [now]
/// switches to that wall clock instead, which is what a test wants when it
/// needs to drive the reset timeout deterministically.
///
/// ```dart
/// final breaker = CircuitBreaker(failureThreshold: 3);
/// final data = await breaker.execute(() => queryReplica());
/// ```
final class CircuitBreaker implements Policy {
  /// Creates a circuit breaker.
  ///
  /// [failureThreshold] is the number of consecutive counted failures that
  /// opens the breaker and must be at least 1. [resetTimeout] is how long
  /// the breaker stays open before allowing a half-open trial.
  ///
  /// [countAs] decides whether an error counts toward the threshold. When
  /// it returns false the error is rethrown but ignored by the breaker: it
  /// does not increment the failure count and does not reopen a half-open
  /// breaker. When null, every error counts.
  ///
  /// [onStateChange] is called with the new state on every transition.
  /// The callback must not throw: an error thrown from it propagates to
  /// the caller in place of the call's own outcome.
  ///
  /// [now] replaces the monotonic default with a wall clock of your choosing.
  /// Pass a fake clock in tests to control the reset timeout; leave it null in
  /// production, where a [Stopwatch] measures the open period and no clock
  /// change can disturb it.
  CircuitBreaker({
    this.failureThreshold = 5,
    this.resetTimeout = const Duration(seconds: 30),
    bool Function(Object error)? countAs,
    void Function(CircuitState state)? onStateChange,
    DateTime Function()? now,
  }) : _countAs = countAs,
       _onStateChange = onStateChange,
       _now = now {
    if (failureThreshold < 1) {
      throw ArgumentError.value(
        failureThreshold,
        'failureThreshold',
        'must be at least 1',
      );
    }
    if (resetTimeout < Duration.zero) {
      throw ArgumentError.value(
        resetTimeout,
        'resetTimeout',
        'must not be negative',
      );
    }
  }

  /// The number of consecutive counted failures that opens the breaker.
  final int failureThreshold;

  /// How long the breaker stays open before allowing a half-open trial.
  final Duration resetTimeout;

  final bool Function(Object error)? _countAs;
  final void Function(CircuitState state)? _onStateChange;

  /// Null in production, where the open period is timed with [_openTimer].
  final DateTime Function()? _now;

  CircuitState _state = CircuitState.closed;
  int _consecutiveFailures = 0;

  /// When the breaker opened, on the injected wall clock. Null unless [_now]
  /// was supplied.
  DateTime? _openedAt;

  /// Time since the breaker opened, counted monotonically. Null unless the
  /// breaker is open and no [_now] was supplied.
  Stopwatch? _openTimer;
  bool _trialInFlight = false;

  /// How long the breaker has been open, or null if it is not open.
  Duration? _sinceOpen() {
    final wallClock = _now;
    if (wallClock != null) {
      final openedAt = _openedAt;
      return openedAt == null ? null : wallClock().difference(openedAt);
    }
    return _openTimer?.elapsed;
  }

  /// The current state of the breaker.
  ///
  /// The open to half-open transition happens lazily on the first call
  /// after [resetTimeout], so this getter can still report
  /// [CircuitState.open] after the timeout has elapsed.
  CircuitState get state => _state;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    _admit();
    final isTrial = _state == CircuitState.halfOpen;
    try {
      final result = await action();
      _onSuccess(isTrial: isTrial);
      return result;
    } catch (error) {
      _onFailure(error, isTrial: isTrial);
      rethrow;
    }
  }

  /// Admits the call or throws [CircuitOpenException].
  ///
  /// Runs synchronously before the action starts, so at most one call can
  /// claim the half-open trial slot.
  void _admit() {
    switch (_state) {
      case CircuitState.closed:
        return;
      case CircuitState.open:
        final remaining = resetTimeout - _sinceOpen()!;
        if (remaining > Duration.zero) {
          throw CircuitOpenException(remaining);
        }
        _transitionTo(CircuitState.halfOpen);
        _trialInFlight = true;
      case CircuitState.halfOpen:
        if (_trialInFlight) {
          throw CircuitOpenException(Duration.zero);
        }
        _trialInFlight = true;
    }
  }

  void _onSuccess({required bool isTrial}) {
    if (isTrial) {
      _trialInFlight = false;
      _consecutiveFailures = 0;
      _openedAt = null;
      _openTimer = null;
      _transitionTo(CircuitState.closed);
    } else if (_state == CircuitState.closed) {
      _consecutiveFailures = 0;
    }
    // A stale success from a call admitted before the breaker opened is
    // ignored.
  }

  void _onFailure(Object error, {required bool isTrial}) {
    final counts = _countAs?.call(error) ?? true;
    if (isTrial) {
      _trialInFlight = false;
      if (counts) {
        _open();
      }
      // An uncounted trial failure keeps the breaker half-open; the next
      // call gets a new trial.
    } else if (_state == CircuitState.closed && counts) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= failureThreshold) {
        _open();
      }
    }
    // A stale failure from a call admitted before the breaker opened is
    // ignored.
  }

  void _open() {
    final wallClock = _now;
    if (wallClock != null) {
      _openedAt = wallClock();
    } else {
      _openTimer = Stopwatch()..start();
    }
    _consecutiveFailures = 0;
    _transitionTo(CircuitState.open);
  }

  void _transitionTo(CircuitState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    _onStateChange?.call(next);
  }
}
