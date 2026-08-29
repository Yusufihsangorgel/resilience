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

To wrap `dart:io` `HttpClient` — policies constructed once, the call
wrapped, a local server that 503s on a script so retry and the breaker
can be watched without a network — run:

```
dart run example/http_recipes.dart
```

Output:

```
Wrapping dart:io HttpClient. Policies live on ResilientClient,
created once. Constructing the breaker inside get() resets it on
every call; consecutive failures never accumulate and it never opens.

a. the server 503s twice, then 200s; retry recovers
   server  GET /recover  -> 503
   attempt 1 failed (HttpException: 503 from /recover), next in 40 ms
   server  GET /recover  -> 503
   attempt 2 failed (HttpException: 503 from /recover), next in 40 ms
   server  GET /recover  -> 200
   ok: {"ok":true}
   3 hits, circuit closed

b. the server stays down; the breaker opens
   server  GET /down  -> 503
   attempt 1 failed (HttpException: 503 from /down), next in 40 ms
   server  GET /down  -> 503
   attempt 2 failed (HttpException: 503 from /down), next in 40 ms
   server  GET /down  -> 503
   breaker -> open
   request 1 gave up after 3 hits: HttpException: 503 from /down
   request 2 cost 0 hits: CircuitOpenException (failed fast, no HTTP call)
   only time reopens a circuit, and the default retryIf knows it
```
