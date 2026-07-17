import 'dart:async';
import 'dart:math';

import 'package:resilience/resilience.dart';

/// Thrown by the fake HTTP client when the upstream is unavailable.
class ServiceUnavailableException implements Exception {
  @override
  String toString() => 'ServiceUnavailableException: 503 from upstream';
}

/// A fake HTTP client that is slow and fails a few times before recovering,
/// like a service coming back after a deploy.
class FlakyHttpClient {
  FlakyHttpClient({this.failuresBeforeRecovery = 2});

  final int failuresBeforeRecovery;
  int _calls = 0;
  final Random _random = Random(7);

  Future<String> getJson(String path) async {
    _calls++;
    await Future<void>.delayed(
      Duration(milliseconds: 20 + _random.nextInt(60)),
    );
    if (_calls <= failuresBeforeRecovery) {
      throw ServiceUnavailableException();
    }
    return '{"path": "$path", "status": "ok", "call": $_calls}';
  }
}

Future<void> main() async {
  final client = FlakyHttpClient();

  // Shared, stateful policies: one breaker and one limiter per upstream.
  final breaker = CircuitBreaker(
    failureThreshold: 5,
    resetTimeout: const Duration(seconds: 10),
    onStateChange: (state) => print('circuit breaker is now $state'),
  );
  final limiter = RateLimiter(
    maxPermits: 5,
    per: const Duration(seconds: 1),
    maxQueueLength: 32,
  );

  // Outermost first: the retry wraps the breaker, the breaker wraps the
  // timeout, and the rate limiter gates every attempt.
  final pipeline = ResiliencePipeline([
    Retry(
      maxAttempts: 4,
      backoff: Backoff.exponential(
        initial: const Duration(milliseconds: 100),
        jitter: 0.5,
      ),
      retryIf: (error) =>
          error is ServiceUnavailableException || error is TimeoutException,
      onRetry: (event) => print(
        'attempt ${event.attempt} failed (${event.error}), '
        'next attempt in ${event.nextDelay.inMilliseconds} ms',
      ),
    ),
    breaker,
    Timeout(const Duration(seconds: 2)),
    limiter,
  ]);

  final body = await pipeline.execute(() => client.getJson('/users/42'));
  print('response: $body');
}
