## 1.1.0

- The README now answers, in its first screen, why to reach for this rather
  than the zero-dependency route or the package that already owns the
  category. Both answers carry the file and line, or the issue number, that
  a reader can check. A "reach for it when" list and a sentence on when to
  skip it follow, because a page that only argues for itself is not useful
  for deciding.

## 1.0.4

- The README leads with the recording of the package working. The file was
  already in the repository and the page never showed it, so a reader had to
  scroll past the prose to find out what the package does, or never found out.

## 1.0.3

- The backoff section shows the jitter rather than describing it.
  `tool/jitter_figure.dart` draws the delays the policy produces. Docs and
  tooling only.

## 1.0.2

- **Fix `RateLimiter` not limiting at all above 1000 permits per second.** The
  refill timer was created with `per ~/ maxPermits`, the ideal spacing of one
  token. Past 1000 permits per second that is sub-millisecond, and a `Timer`
  resolves in whole milliseconds: the period rounded down to zero. The timer
  fired on every event-loop turn and granted a token each time.
  Measured: a limiter configured for 1001 permits per second let 2002 calls
  through in 10 ms rather than the second they were paced for, roughly a
  hundred times the configured rate. A caller who put this in front of an API
  with a 5000/s quota was sending about 97,000/s and collecting 429s.

  The timer now ticks no faster than 4 ms and releases however many tokens the
  elapsed period has earned, carrying the sub-token remainder so a rate that
  does not divide evenly into the tick does not drift. Rates at or below 250
  permits per second are unaffected, since their interval already exceeds the
  floor. Measured after the fix, at 50, 100, 1001, 2000 and 5000 permits per
  second: all within 1% of the configured rate.

  A regression test covers 1001 and 5000 permits per second and fails against
  the old implementation.

## 1.0.1

- Add `example/README.md` for pub.dev's Example tab (it was empty). It walks a
  `CircuitBreaker` through its full lifecycle (open, fail-fast, half-open,
  closed) against a recovering dependency, with the real output. Docs only.

## 1.0.0

First stable release. The public API is frozen: from here a breaking change
will not land without a major-version bump.

No code changes since 0.4.0. This release is the commitment, made after an
adversarial review that ran the policies rather than reading them: a
sync-throw sweep across all seven policies plus the pipeline and
`withFallback` under `runZonedGuarded` (no escapes, no hangs), timer-leak
accounting under `fake_async`, a 300-task bulkhead storm holding the
concurrency ceiling, ten-way contention for the circuit breaker's half-open
trial, and both pathological caveats in the docs executed to confirm they
behave as documented.

What the freeze commits to:

- Every concrete policy is `final`. Composition, not inheritance, is the
  extension path, and `ResiliencePipeline` is how policies combine.
- `Policy` and `Backoff` stay open as single-method interfaces for writing
  your own policy or backoff. Neither can gain a member in 1.x.
- `Policy.execute` takes a `Future<T> Function()`. A synchronous throw from
  the action is routed through the normal error path by every policy; a
  plain function wraps as `() async => ...` with nothing lost.
- No type carries value equality: the policies are stateful service objects,
  and `RetryEvent` is a callback payload holding a `StackTrace`.
- Every export is named. Zero runtime dependencies; the public API uses only
  SDK types.

## 0.4.0

- Fix `Hedge` hanging on an action that throws synchronously. A hedged call
  runs the action from a `Timer` callback; if the action threw before it
  returned a future (a closed `http.Client` does exactly this), the throw
  escaped as an unhandled zone error, the returned future never completed, and
  the caller awaited forever. Every other policy already routes a synchronous
  throw through its normal error path; `Hedge` now does too, by invoking the
  action with `Future.sync`. Regression tests cover an action that throws on
  every attempt and one that throws only on the hedged attempt.
- Name every export explicitly with a `show` clause. The library re-exported
  whole source files; a symbol that became public in one would have joined
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
  seconds, and it is now opt-in: pass `retryIf: (error) => true`. The README
  says when that is worth doing.
- The circuit breaker's reset timeout is now measured monotonically with a
  `Stopwatch`, so a system clock change cannot shorten or extend the open
  period. The doc comment promised this "in 0.2" and 0.2.1 still used the wall
  clock. Passing `now` still switches to a wall clock of your choosing, which
  is what a test wants; production no longer has one.

## 0.2.1

- Declare the diagram in `pubspec.yaml` so pub.dev renders it on the package
  page. It was already in the repository and the README, but pub.dev shows only
  what the `screenshots:` field points at. The page opened with prose where
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
  call is failing. The outermost position is the only correct one, and the only
  one the API offers, which also keeps the substitute typed to the
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
