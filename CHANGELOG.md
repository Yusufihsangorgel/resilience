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
