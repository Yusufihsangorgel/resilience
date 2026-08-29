# AGENTS.md

This package wraps a `Future<T> Function()` in composable `Policy` objects (`Retry`, `CircuitBreaker`, `Timeout`, `RateLimiter`, `Bulkhead`, `Hedge`) and nests them with `ResiliencePipeline`. `withFallback` sits outside that stack and returns a substitute when the policies still fail.

It does not cancel work. Cancellation in Dart is cooperative, and a `Future` has nothing to cooperate with: `Timeout.execute` is `action().timeout(duration)`, so when the deadline fires the caller gets a `TimeoutException` (dart:async) and the action keeps running; a late result is discarded (`test/timeout_test.dart`). The policy bounds how long the waiter blocks, not how long the work runs.

## Usage

From `example/resilience_example.dart`: Retry outermost, Timeout inside the breaker so a half-open trial always settles, limiter innermost. `breaker` and `limiter` are created once, not per call.

```dart
import 'package:resilience/resilience.dart';

final breaker = CircuitBreaker(
  failureThreshold: 3,
  resetTimeout: const Duration(milliseconds: 400),
);
final limiter = RateLimiter(
  maxPermits: 4,
  per: const Duration(milliseconds: 120),
  maxQueueLength: 32,
);
final pipeline = ResiliencePipeline([
  Retry(
    maxAttempts: 3,
    backoff: const Backoff.fixed(Duration(milliseconds: 40)),
  ),
  breaker,
  const Timeout(Duration(milliseconds: 250)),
  limiter,
]);

final body = await pipeline.execute(() => api.get('/users/42'));
```

`maxAttempts` includes the first try. Catch `TimeoutException` with `import 'dart:async'`; this package does not re-export it.

## Contracts

**Pipeline order.** `ResiliencePipeline` wraps outside-in: index 0 is outermost, i.e. `retry.execute(() => breaker.execute(() => timeout.execute(() => limiter.execute(action))))` (`ResiliencePipeline.execute`). That order is not cosmetic.

- Retry outside `CircuitBreaker`: once open, the breaker throws `CircuitOpenException` without running the action, and the default retry stops. Breaker outside Retry: one exhausted retry counts as a single failure toward `failureThreshold`.
- Timeout inside the breaker: the half-open trial must settle. A trial that never completes leaves `CircuitState.halfOpen` and every other call gets `CircuitOpenException(Duration.zero)`. Timeout outside Retry is a total budget; inside Retry it is per attempt.
- `RateLimiter` / `Bulkhead` innermost: each attempt pays a token or occupies a slot. Outside Retry, the limiter charges once per caller and the bulkhead holds a slot for the whole retry, including backoff.

**`retryIf`.** When omitted, `Retry` retries every error except `CircuitOpenException`. A supplied `retryIf` replaces that default entirely. If it returns true for `CircuitOpenException`, every call against an open circuit burns `maxAttempts` and sleeps every backoff on work that never ran, so the breaker cannot fail fast. The predicate must return false for `CircuitOpenException` unless the backoff can outlast `resetTimeout`.

**Instance state.** `CircuitBreaker` (`state`), `RateLimiter` (token bucket), and `Bulkhead` (`activeCount`) store state on the instance. One long-lived object per protected resource, shared across callers. `Retry`, `Timeout`, and `Hedge` are stateless. Building a new `ResiliencePipeline` per call is fine if it wraps those shared instances; constructing the breaker, limiter, or bulkhead inside the pipeline list is not.

## Mistakes

- `CircuitBreaker(...)` (or a `ResiliencePipeline` that constructs one) inside the function it protects. Symptom: consecutive failures never accumulate; the breaker never opens. Fix: a field, created once.
- `RateLimiter(...)` or `Bulkhead(...)` inside that function. Symptom: every call gets a full bucket or a free slot; nothing is limited. Fix: share one instance.
- `retryIf: (_) => true`, or any predicate that accepts `CircuitOpenException`. Symptom: open circuits still wait out retries. Fix: omit `retryIf`, or return false for `CircuitOpenException`.
- `countAs` that returns false for the errors the action actually throws. Symptom: `state` stays `CircuitState.closed`. Fix: count those errors, or omit `countAs`.
- `execute(() => alreadyStarted)` where `alreadyStarted` is a `Future` in flight. Symptom: retry and hedge replay a completed future. Fix: start work in the thunk (`() => client.get(url)`).
- `withFallback` wrapped around the action inside `Retry` or `CircuitBreaker`. Symptom: they see success; retries stop; the breaker never opens. Fix: `withFallback(pipeline, action, fallback: ...)`. It is a function, not a `Policy`, so it cannot go in the list.
- Treating `Timeout` as abort. Symptom: `Bulkhead.activeCount` drops while the dependency still runs (`example/resilience_example.dart`, scene d). Fix: clean up in the action; do not equate bulkhead slots with real in-flight work.
- Hedging a non-idempotent write. Symptom: duplicate side effects; losers still run to completion. Fix: reads, or writes an idempotency key makes safe; set `Hedge.delay` near p95, not the median.
- Reading `maxAttempts: 3` as three retries. It is three attempts total.
- Queue defaults: `RateLimiter.maxQueueLength` is null (unbounded wait); `Bulkhead.maxQueued` is 0 (immediate `BulkheadRejectedException`).

## Layout

- Public API: `lib/resilience.dart`. Import `package:resilience/resilience.dart`. Do not import `lib/src/`.
- Implementations: `lib/src/*.dart`
- Tests: `test/` — `dart test`
- Examples: `dart run example/breaker_demo.dart`, `dart run example/resilience_example.dart`, `dart run example/hedge_tail_latency.dart`
- Analyze: `dart analyze`
