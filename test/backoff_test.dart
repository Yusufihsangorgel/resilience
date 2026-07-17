import 'dart:math';

import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

/// A [Random] that returns a fixed sequence of doubles.
class SequenceRandom implements Random {
  SequenceRandom(this._values);

  final List<double> _values;
  int _index = 0;

  @override
  double nextDouble() => _values[_index++ % _values.length];

  @override
  int nextInt(int max) => (nextDouble() * max).floor();

  @override
  bool nextBool() => nextDouble() >= 0.5;
}

void main() {
  group('Backoff.none', () {
    test('returns zero for every attempt', () {
      const backoff = Backoff.none();
      expect(backoff.delay(1), Duration.zero);
      expect(backoff.delay(2), Duration.zero);
      expect(backoff.delay(100), Duration.zero);
    });
  });

  group('Backoff.fixed', () {
    test('returns the configured delay for every attempt', () {
      const backoff = Backoff.fixed(Duration(milliseconds: 250));
      expect(backoff.delay(1), const Duration(milliseconds: 250));
      expect(backoff.delay(5), const Duration(milliseconds: 250));
    });
  });

  group('Backoff.exponential', () {
    test('grows by factor per attempt with the defaults', () {
      final backoff = Backoff.exponential();
      expect(backoff.delay(1), const Duration(milliseconds: 200));
      expect(backoff.delay(2), const Duration(milliseconds: 400));
      expect(backoff.delay(3), const Duration(milliseconds: 800));
      expect(backoff.delay(4), const Duration(milliseconds: 1600));
    });

    test('caps the delay at max', () {
      final backoff = Backoff.exponential(
        initial: const Duration(seconds: 1),
        factor: 10,
        max: const Duration(seconds: 5),
      );
      expect(backoff.delay(1), const Duration(seconds: 1));
      expect(backoff.delay(2), const Duration(seconds: 5));
      expect(backoff.delay(100), const Duration(seconds: 5));
    });

    test('applies full jitter as base * random when jitter is 1', () {
      final backoff = Backoff.exponential(
        initial: const Duration(milliseconds: 1000),
        jitter: 1,
        random: SequenceRandom([0.0, 0.5, 1.0 - 1e-9]),
      );
      expect(backoff.delay(1), Duration.zero);
      expect(backoff.delay(1), const Duration(milliseconds: 500));
      expect(backoff.delay(1), const Duration(milliseconds: 1000));
    });

    test('applies partial jitter with the documented formula', () {
      // effective = base * (1 - jitter) + base * jitter * random
      final backoff = Backoff.exponential(
        initial: const Duration(milliseconds: 1000),
        jitter: 0.4,
        random: SequenceRandom([0.25]),
      );
      // 1000 * 0.6 + 1000 * 0.4 * 0.25 = 700.
      expect(backoff.delay(1), const Duration(milliseconds: 700));
    });

    test('rejects invalid arguments', () {
      expect(() => Backoff.exponential(factor: 0.5), throwsArgumentError);
      expect(() => Backoff.exponential(jitter: -0.1), throwsArgumentError);
      expect(() => Backoff.exponential(jitter: 1.1), throwsArgumentError);
      expect(
        () => Backoff.exponential(initial: const Duration(seconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => Backoff.exponential(max: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('rejects attempt numbers below 1', () {
      final backoff = Backoff.exponential();
      expect(() => backoff.delay(0), throwsRangeError);
      expect(() => backoff.delay(-1), throwsRangeError);
    });
  });
}
