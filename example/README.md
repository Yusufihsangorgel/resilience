# resilience example

`breaker_demo.dart` walks a `CircuitBreaker` through its whole lifecycle against
a fake dependency that is down and then recovers: the breaker trips open after
enough failures, fails fast without touching the network while open, tries once
in half-open, and closes again when the call succeeds.

```dart
final breaker = CircuitBreaker(
  failureThreshold: 3,
  resetTimeout: const Duration(milliseconds: 900),
  onStateChange: (state) => print('breaker -> ${state.name}'),
);

// While the breaker is open, execute throws CircuitOpenException without
// ever calling `upstream`, so a failing dependency stops costing you latency.
final body = await breaker.execute(upstream.call);
```

Run it:

```
dart run example/breaker_demo.dart
```

Output:

```
A dependency is down. The breaker opens, then it recovers.

  call 1   failed (503)
  call 2   failed (503)
  breaker -> open
  call 3   failed (503)
  call 4   fail fast (breaker open, no network call)
  call 5   fail fast (breaker open, no network call)
  breaker -> halfOpen
  breaker -> closed
  call 6   ok: {"status": "ok"}
```

The breaker is one of the policies in the package; `Retry`, `Timeout`,
`RateLimiter`, `Bulkhead` and `Hedge` compose with it through a
`ResiliencePipeline`. See the package README for combining them.
