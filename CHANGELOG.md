## 0.4.0

- Fix `Hedge` hanging on an action that throws synchronously. A hedged call
  runs the action from a `Timer` callback; if the action threw before it
  returned a future — a closed `http.Client` does exactly this — the throw
  escaped as an unhandled zone error and the returned future never completed,
  so the caller awaited forever. Every other policy already routes a synchronous
  throw through its normal error path; `Hedge` now does too, by invoking the
  action with `Future.sync`. Regression tests cover an action that throws on
  every attempt and one that throws only on the hedged attempt.
- Name every export explicitly with a `show` clause. The library re-exported
  whole source files, so a symbol that became public in one would have joined
  the API by accident. The exported set is unchanged: `Backoff`, `Bulkhead`,
  `BulkheadRejectedException`, `CircuitBreaker`, `CircuitOpenException`,
  `CircuitState`, `Hedge`, `Policy`, `RateLimiter`, `RateLimitExceededException`,
  `ResiliencePipeline`, `Retry`, `RetryEvent`, `Timeout`, and `withFallback`.
- Repair the pub.dev screenshot caption, which a folded YAML line had split
  mid-word into "CircuitBreake r".

## 0.3.0

- **Behaviour change:** `Retry` no longer retries `CircuitOpenException` by
  default. A breaker throws it without calling the action, so a retry wrapped
  around a breaker used to spend its whole budget, and sleep through every
  backoff delay, on calls that were never made. Measured in the new test: with
  `maxAttempts: 10` and a breaker that opens after 3 failures, the old default
  ran 9 retries for 3 real calls; it now runs 3 and stops.
  The old behaviour had one real use, which is why it was the default: if the
  backoff can outlast the breaker's `resetTimeout`, a later attempt arrives
  after the circuit is willing to half-open. That needs delays of tens of
  seconds, so it is now opt-in — pass `retryIf: (error) => true`. The README
  says when that is worth doing.
- The circuit breaker's reset timeout is now measured monotonically with a
  `Stopwatch`, so a system clock change cannot shorten or extend the open
  period. The doc comment promised this "in 0.2" and 0.2.1 still used the wall
  clock. Passing `now` still switches to a wall clock of your choosing, which
  is what a test wants; production no longer has one.

## 0.2.1

- Declare the diagram in `pubspec.yaml` so pub.dev renders it on the package
  page. It was already in the repository and the README, but pub.dev shows only
  what the `screenshots:` field points at, so the page opened with prose where
  the picture should have been.

## 0.2.0

- Add `Hedge`, which starts a second copy of a slow call rather than waiting
  for it and takes whichever finishes first. Retrying cannot help a call that
  is merely slow, since a retry only begins once the slow attempt has already
  failed. A failed attempt brings the next one forward instead of waiting out
  the delay, losers are ignored, and if every attempt fails the last error is
  thrown. Only hedge calls that are safe to run twice.
- Add `withFallback`, which returns a substitute value when the policy around
  it still failed, for serving cached or default data instead of an exception.
  It is a function taking a policy rather than a policy itself: a fallback
  swallows the error, so inside a retry the retry would see success and never
  run again, and inside a circuit breaker the breaker would never learn the
  call is failing. The outermost position is the only correct one, so it is the
  only one the API offers, which also keeps the substitute typed to the
  action's result.

## 0.1.2

- Docs: sharpen the pub.dev description to lead with the value and the terms people search.

## 0.1.1

- Docs: tightened the README wording and visuals.

## 0.1.0

Initial release.

- `Retry` with `Backoff.none`, `Backoff.fixed`, and `Backoff.exponential`
  (factor, cap, and jitter), plus `retryIf` and `onRetry` hooks.
- `CircuitBreaker` with consecutive failure threshold, lazy reset timeout,
  single half-open trial, `countAs` filter, and `onStateChange` hook.
- `Timeout` built on `Future.timeout`.
- `RateLimiter`: token bucket with steady refill, FIFO waiting, an
  optional queue bound, and `dispose`.
- `Bulkhead`: concurrency limit with a bounded FIFO queue.
- `ResiliencePipeline` for composing policies, outermost first.
