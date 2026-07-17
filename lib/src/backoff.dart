import 'dart:math';

/// A strategy that computes the delay before the next retry attempt.
///
/// Implement this interface to supply a custom strategy, or use one of the
/// built-in factories: [Backoff.none], [Backoff.fixed], and
/// [Backoff.exponential].
abstract interface class Backoff {
  /// No delay: every retry happens immediately.
  const factory Backoff.none() = _NoneBackoff;

  /// The same [delay] before every retry.
  const factory Backoff.fixed(Duration delay) = _FixedBackoff;

  /// An exponentially growing delay with optional jitter.
  ///
  /// The base delay for attempt `n` (1-based) is
  /// `initial * factor^(n - 1)`, capped at [max]. With the defaults the
  /// sequence is 200 ms, 400 ms, 800 ms, and so on, up to 30 seconds.
  ///
  /// [jitter] must be between 0 and 1 and randomizes the delay to spread
  /// out retries from many clients:
  ///
  /// ```
  /// effective = base * (1 - jitter) + base * jitter * random
  /// ```
  ///
  /// where `random` is a uniform value in [0, 1). With `jitter: 0` the
  /// delay is exactly the base value. With `jitter: 1` it is a uniform
  /// value between zero and the base value.
  ///
  /// Pass [random] to make jitter deterministic in tests.
  factory Backoff.exponential({
    Duration initial = const Duration(milliseconds: 200),
    double factor = 2,
    Duration max = const Duration(seconds: 30),
    double jitter = 0,
    Random? random,
  }) {
    return _ExponentialBackoff(
      initial: initial,
      factor: factor,
      max: max,
      jitter: jitter,
      random: random,
    );
  }

  /// Returns the delay to wait after failed attempt number [attempt].
  ///
  /// [attempt] is 1-based: the first failed attempt is 1.
  Duration delay(int attempt);
}

final class _NoneBackoff implements Backoff {
  const _NoneBackoff();

  @override
  Duration delay(int attempt) => Duration.zero;
}

final class _FixedBackoff implements Backoff {
  const _FixedBackoff(this._delay);

  final Duration _delay;

  @override
  Duration delay(int attempt) => _delay;
}

final class _ExponentialBackoff implements Backoff {
  _ExponentialBackoff({
    required this.initial,
    required this.factor,
    required this.max,
    required this.jitter,
    Random? random,
  }) : _random = random ?? Random() {
    if (initial < Duration.zero) {
      throw ArgumentError.value(initial, 'initial', 'must not be negative');
    }
    if (factor < 1) {
      throw ArgumentError.value(factor, 'factor', 'must be at least 1');
    }
    if (max < Duration.zero) {
      throw ArgumentError.value(max, 'max', 'must not be negative');
    }
    if (jitter < 0 || jitter > 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be between 0 and 1');
    }
  }

  final Duration initial;
  final double factor;
  final Duration max;
  final double jitter;
  final Random _random;

  @override
  Duration delay(int attempt) {
    if (attempt < 1) {
      throw RangeError.range(attempt, 1, null, 'attempt');
    }
    final cap = max.inMicroseconds.toDouble();
    var base = initial.inMicroseconds * pow(factor, attempt - 1).toDouble();
    if (base > cap) {
      base = cap;
    }
    final effective =
        base * (1 - jitter) + base * jitter * _random.nextDouble();
    return Duration(microseconds: effective.round());
  }
}
