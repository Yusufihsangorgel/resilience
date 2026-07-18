// A short demo for the write-up: a dependency is down for a moment, the
// circuit breaker opens and fails fast, then the dependency recovers and the
// breaker closes. Run with: dart run example/breaker_demo.dart
import 'dart:async';

import 'package:resilience/resilience.dart';

/// A fake upstream that is down for the first 1.5 seconds, then recovers.
class Upstream {
  final Stopwatch _since = Stopwatch()..start();

  Future<String> call() async {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (_since.elapsedMilliseconds < 1500) {
      throw StateError('503 from upstream');
    }
    return '{"status": "ok"}';
  }
}

Future<void> main() async {
  final upstream = Upstream();
  final breaker = CircuitBreaker(
    failureThreshold: 3,
    resetTimeout: const Duration(milliseconds: 900),
    onStateChange: (state) => print('  breaker -> ${state.name}'),
  );

  print('');
  print('A dependency is down. The breaker opens, then it recovers.');
  print('');

  for (var i = 1; i <= 9; i++) {
    try {
      final body = await breaker.execute(upstream.call);
      print('  call $i   ok: $body');
      break;
    } on CircuitOpenException {
      print('  call $i   fail fast (breaker open, no network call)');
    } on StateError {
      print('  call $i   failed (503)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
