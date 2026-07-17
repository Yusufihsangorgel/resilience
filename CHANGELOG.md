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
