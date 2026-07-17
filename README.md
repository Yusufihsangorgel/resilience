# resilience

Retry with backoff and jitter, circuit breaker, timeout, rate limiter, and
bulkhead policies for reliable async operations. Zero dependencies.

Network calls fail, dependencies slow down, and third-party APIs throttle.
This package packages the standard answers to those problems as small,
composable policy objects with one shared interface:

```dart
abstract interface class Policy {
  Future<T> execute<T>(Future<T> Function() action);
}
```

Every policy wraps an async action. Policies compose through
`ResiliencePipeline`, and the whole package has no dependencies outside the
Dart SDK.

## Policies

| Policy | What it does |
| --- | --- |
| `Retry` | Runs the action again after a failure, with configurable backoff and jitter |
| `CircuitBreaker` | Fails fast after repeated failures so a broken dependency can recover |
| `Timeout` | Fails the call when the action takes too long |
| `RateLimiter` | Limits how often actions start, using a token bucket |
| `Bulkhead` | Limits how many actions run concurrently |
| `ResiliencePipeline` | Composes any of the above into one policy |

## Install

```sh
dart pub add resilience
```

## Retry

```dart
import 'package:resilience/resilience.dart';

final retry = Retry(
  maxAttempts: 4,
  backoff: Backoff.exponential(
    initial: Duration(milliseconds: 200),
    factor: 2,
    max: Duration(seconds: 30),
    jitter: 0.5,
  ),
  retryIf: (error) => error is TimeoutException,
  onRetry: (event) => log('attempt ${event.attempt} failed: ${event.error}'),
);

final data = await retry.execute(() => fetchData());
```

`maxAttempts` counts the first attempt, so `maxAttempts: 4` means one
initial call plus up to three retries. When `retryIf` is omitted, every
error is retried. The last attempt rethrows the original error.

Backoff strategies:

- `Backoff.none()`: retry immediately.
- `Backoff.fixed(duration)`: the same delay every time.
- `Backoff.exponential(...)`: `initial * factor^(attempt - 1)`, capped at
  `max`. `jitter` between 0 and 1 randomizes each delay within
  `[base * (1 - jitter), base]` so simultaneous clients do not retry in
  lockstep.

`Backoff` is an interface, so a custom schedule is one small class away.

## Circuit breaker

A circuit breaker stops calling a dependency that keeps failing, then
probes it once in a while until it recovers. Create one breaker per
dependency and share it between callers; the state lives in the instance.

```dart
final breaker = CircuitBreaker(
  failureThreshold: 5,
  resetTimeout: Duration(seconds: 30),
  onStateChange: (state) => log('search backend circuit: $state'),
);

final results = await breaker.execute(() => searchBackend(query));
```

After `failureThreshold` consecutive failures the breaker opens and every
call throws `CircuitOpenException` without running the action. The
exception carries `retryAfter`, the time left until the breaker allows a
trial. After `resetTimeout` the breaker admits exactly one trial call:
success closes the circuit, failure reopens it.

`countAs` filters which errors count toward the threshold. Errors it
rejects are rethrown but do not affect the breaker state:

```dart
final breaker = CircuitBreaker(
  countAs: (error) => error is! ArgumentError,
);
```

## Timeout

```dart
const timeout = Timeout(Duration(seconds: 2));
final page = await timeout.execute(() => fetchPage(url));
```

Throws `TimeoutException` when the action takes longer than the given
duration.

One honest caveat: Dart futures cannot be cancelled. When the timeout
fires, the underlying action keeps running and its eventual result or
error is discarded. `Timeout` bounds how long the caller waits, not how
long the work runs. If the action holds a scarce resource, pair it with a
`Bulkhead` or handle cleanup inside the action.

## Rate limiter

A token bucket. The bucket holds `maxPermits` tokens and refills at a
steady rate of `maxPermits` per `per` (one token every `per / maxPermits`).
Each call consumes one token before starting, so a full bucket allows a
short burst and sustained load proceeds at the refill rate.

```dart
final limiter = RateLimiter(
  maxPermits: 10,
  per: Duration(seconds: 1),
  maxQueueLength: 100,
);

final response = await limiter.execute(() => callThirdPartyApi());
```

When no token is available the call waits in a FIFO queue. If the queue
already holds `maxQueueLength` calls, the new call fails with
`RateLimitExceededException` instead of waiting. Leave `maxQueueLength`
null for an unbounded queue, or set it to 0 to fail immediately whenever
no token is available.

## Bulkhead

A concurrency limit. At most `maxConcurrent` actions run at once; up to
`maxQueued` more wait in FIFO order, and beyond that calls fail with
`BulkheadRejectedException`.

```dart
final bulkhead = Bulkhead(maxConcurrent: 4, maxQueued: 16);
final report = await bulkhead.execute(() => renderReport(id));
```

A bulkhead keeps one slow dependency from soaking up every worker in the
process: the dependency saturates its own slots and the rest of the app
keeps running.

## Composing policies

`ResiliencePipeline` wraps policies from the outside in; the first policy
in the list is the outermost.

```dart
final pipeline = ResiliencePipeline([
  Retry(maxAttempts: 3, backoff: Backoff.exponential(jitter: 0.5)),
  breaker,
  Timeout(Duration(seconds: 2)),
  limiter,
]);

final user = await pipeline.execute(() => fetchUser(id));
```

This reads as: the retry wraps the breaker, which wraps the timeout, which
wraps the rate limiter, which gates the action. Order matters:

- Retry outside the breaker: the breaker's own `CircuitOpenException` is
  retried too, which gives the breaker a chance to half-open between
  attempts.
- Breaker outside the retry: one fully exhausted retry counts as a single
  failure toward opening the circuit.

A pipeline is itself a `Policy`, so pipelines can be nested and shared.
See `example/resilience_example.dart` for a complete program.

## Testability

The parts that involve randomness or time accept injectable seams:
`Backoff.exponential` takes a `Random`, and `CircuitBreaker` takes a
`now` function. Retry delays, rate limiter refills, and timeouts are
driven by timers, so they work with `package:fake_async` out of the box.

## Design notes

- Zero runtime dependencies; only the Dart SDK.
- Policies are plain objects. `Retry`, `Timeout`, and backoffs are
  stateless and reusable anywhere. `CircuitBreaker`, `RateLimiter`, and
  `Bulkhead` are stateful by design: create one per protected resource and
  share it.
- No global registry, no configuration files, no code generation.
