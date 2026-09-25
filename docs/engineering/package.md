# Package engineering rules: resilience

Rules-Version: resilience/ea67b96f73cf24a63bcc733a4c40b24025d60f1f44044e4fb8cb855cef14e33c
Core-Version: 1
Core-Digest: 1825fa7ff346dca23e65b1b3bf9b2e3e06959f1414bae9952d596d2f62f09b8f
Survey-Digest: f90f45c8a172068c3ed3b9488ba5a7cb4e58efa93c380d2d9a70b399349ec35e
Evidence-Revision: 388cda4
Verified-Revision: unverified

Read CONTRIBUTING.md and docs/engineering/debt.json before editing.

## Current architecture
HEAD 388cda4 (2026-08-29), v1.1.3, sdk ^3.8.0 (tall formatter style), zero runtime dependencies (dev: fake_async, lints, test). Policy/strategy library: one abstraction `Policy.execute<T>(Future<T> Function())` (policy.dart:6-12); each policy is a `final class X implements Policy` in its own file (Retry, CircuitBreaker, Timeout, RateLimiter, Bulkhead, Hedge). `ResiliencePipeline` is a composite that is itself a Policy; `withFallback` is deliberately a function (outermost position only). `Backoff` is a strategy interface, const factory redirections go to private implementations. Policies are documented as stateful (one instance per resource) or stateless (shareable). Flat lib/src, 10 files, ~1,100 lines: one file per policy; no extra layer needed.

## Layers and responsibilities
- lib/resilience.dart: Explicit `show` lists (lines 9-19); the library dartdoc carries the zero-dependency promise (5-6).
- lib/src/policy.dart: `abstract interface class Policy` with the single method `execute<T>`.
- lib/src/{retry,circuit_breaker,timeout,rate_limiter,bulkhead,hedge}.dart: Each file one policy + its own rejection exception/event type (RetryEvent, CircuitOpenException, CircuitState, RateLimitExceededException, BulkheadRejectedException).
- lib/src/backoff.dart: `Backoff` interface + const factory → `_NoneBackoff`, `_FixedBackoff`, `_ExponentialBackoff` (jitter, injectable Random).
- lib/src/pipeline.dart, lib/src/fallback.dart: `ResiliencePipeline` wraps outer-to-inner; `withFallback` is the outermost substitution value.
- tool/jitter_figure.dart: Generates the doc/jitter figure; imports only the barrel.

## Public API and dependency direction
`Backoff`; `Bulkhead`, `BulkheadRejectedException`; `CircuitBreaker`, `CircuitOpenException`, `CircuitState`; `withFallback`; `Hedge`; `ResiliencePipeline`; `Policy`; `RateLimiter`, `RateLimitExceededException`; `Retry`, `RetryEvent`; `Timeout` (lib/resilience.dart:9-19). Backoff implementations are private. Caution: `Retry` and `Timeout` clash with package:test names; tests use `hide Retry, Timeout`.

Every policy → policy.dart (the single shared abstraction). retry.dart → backoff.dart + circuit_breaker.dart (only to not retry `CircuitOpenException` by default; rationale at retry.dart:55-65). pipeline.dart, fallback.dart → policy.dart. policy.dart and backoff.dart import no internal module (roots). Only dart:async/collection/math. No cycles. Tests, examples, tool depend only on the barrel.

## Error, state and platform contracts
- `final class X implements Policy` + early validation in the constructor `ArgumentError.value(value, 'name', 'must ...')` (retry.dart:78-84, bulkhead.dart:49-60, circuit_breaker.dart:94-107, rate_limiter.dart:64-84, hedge.dart:39-50, backoff.dart:79-90); Timeout is the const-constructor exception, it defers the check to execute and documents this (timeout.dart:18-33).
- One rejection exception per policy: const constructor, fields that carry the limit, 'XException: ...' toString; no common base (bulkhead.dart:8-25, circuit_breaker.dart:18-31, rate_limiter.dart:8-20). StateError for misuse (rate_limiter.dart:110, 133).
- User callbacks: optional function parameter → private field; 'must not throw' and the result are documented (retry.dart:67-70, circuit_breaker.dart:77-79).
- Test seams: `Random? random` (backoff.dart:32, 38), `DateTime Function()? now` (circuit_breaker.dart:81-93); time via Timer (fake_async can drive it); default monotonic Stopwatch (circuit_breaker.dart:56-59).
- State contract in dartdoc: stateful 'one instance per protected resource' (bulkhead.dart:37-38, circuit_breaker.dart:36-37, rate_limiter.dart:37-38), stateless 'can be shared' (retry.dart:37-38).
- FIFO `Queue<Completer<void>>` waiters and concurrency slot handover (bulkhead.dart:69, 97-100; rate_limiter.dart:97, 224-229).
- Streaming/cancellation: Dart futures cannot be cancelled; this is explicitly documented (timeout.dart:7-11, hedge.dart:22-25). No background timer, transitions are lazy (circuit_breaker.dart:44-46); the RateLimiter timer stops with dispose (rate_limiter.dart:116-135).
- Constants chosen by measurement are justified in the body (rate_limiter.dart:165-188 `_minTick`).
- No FFI, no platform checks, no dart:io (lib is platform-independent; CI is VM only).

## Package rules
### resilience/RES-1 [MUST]
Add a new behavior as a `final class` that implements `Policy` with a single `execute<T>`, in its own file under lib/src, exported through the `show` list in lib/resilience.dart. It must work inside `ResiliencePipeline` with no special case.
Reason: The Policy interface is the package's single extension point (OCP/DIP); the pipeline treats every policy the same. All 6 current policies follow this form.
Evidence: lib/src/policy.dart:6-12; lib/src/pipeline.dart:24-43; lib/resilience.dart:9-19
Evidence role: current-pattern
Existing violation: none

### resilience/RES-2 [MUST_NOT]
Do not add a runtime dependency. The package promises zero dependencies outside the Dart SDK.
Reason: The pubspec description and the library dartdoc promise zero dependencies; there is no dependencies block in the pubspec.
Evidence: pubspec.yaml (description 'Zero dependencies', no dependencies); lib/resilience.dart:5-6
Evidence role: current-pattern
Existing violation: none

### resilience/RES-3 [MUST]
Validate constructor arguments eagerly with `ArgumentError.value(value, 'name', 'must ...')`. Only a const constructor may defer the check to `execute`, and its dartdoc says it does.
Reason: The same pattern in six places; the Timeout exception is documented because a const constructor cannot compare Durations.
Evidence: lib/src/retry.dart:78-84; lib/src/bulkhead.dart:49-60; lib/src/circuit_breaker.dart:94-107; lib/src/rate_limiter.dart:64-84; lib/src/hedge.dart:39-50; lib/src/backoff.dart:79-90; lib/src/timeout.dart:18-33
Evidence role: current-pattern
Existing violation: none

### resilience/RES-4 [MUST]
Report a rejection with a dedicated `final class <Name>Exception implements Exception` that carries the limit that caused it and prints `<Name>Exception: ...`. Keep `StateError` for misuse such as calling a disposed limiter.
Reason: Users distinguish rejections by type (the Retry default recognizes CircuitOpenException by type); the three current rejection exceptions behave the same.
Evidence: lib/src/bulkhead.dart:8-25; lib/src/circuit_breaker.dart:18-31; lib/src/rate_limiter.dart:8-20, 109-111; lib/src/retry.dart:103-105
Evidence role: current-pattern
Existing violation: none

### resilience/RES-5 [MUST]
Keep time and randomness testable: take an injectable clock or `Random`, or schedule with `Timer` to let fake_async drive it. A policy must not read the wall clock without such a seam.
Reason: Policy correctness depends on time; tests are deterministic with fake_async and an injected clock. Shared J7 (clock/async ecosystem) is satisfied here by injection because of zero dependencies.
Evidence: lib/src/backoff.dart:32, 38, 78; lib/src/circuit_breaker.dart:56-59, 81-93, 119-142; lib/src/rate_limiter.dart:162; test/rate_limiter_test.dart:3; test/timeout_test.dart:3
Evidence role: current-pattern
Existing violation: none

### resilience/RES-6 [MUST]
State the sharing contract in the class dartdoc: a stateful policy says to create one instance per protected resource and share it; a stateless one says it can be shared.
Reason: The most common usage mistake is to create the policy inside the protected function (CHANGELOG 1.1.3 explains this); the contract is in the dartdoc.
Evidence: lib/src/bulkhead.dart:37-38; lib/src/circuit_breaker.dart:36-37; lib/src/rate_limiter.dart:37-38; lib/src/retry.dart:37-38
Evidence role: current-pattern
Existing violation: none

### resilience/RES-7 [MUST]
Keep imports between policy files to exception types with a documented reason. Today the only one is retry.dart importing circuit_breaker.dart to skip `CircuitOpenException` by default.
Reason: Policies must stay independent of each other; the single cross-link is documented and exists only for the exception type.
Evidence: lib/src/retry.dart:1-3, 55-65, 103-105; import graph (the other policies import only policy.dart)
Evidence role: current-pattern
Existing violation: none

### resilience/RES-8 [MUST]
Keep the analyzer settings: strict casts, strict inference, strict raw types, `public_member_api_docs` and `unawaited_futures`. Document every public member and add no `// ignore:` comments.
Reason: The package's current quality baseline; 0 ignores today. Shared D2 DOC-PUBLIC is already enforced by the analyzer.
Evidence: analysis_options.yaml:1-15; lib/test/example/tool grep: 0 ignore
Evidence role: current-pattern
Existing violation: none

### resilience/RES-9 [MUST]
Tests import only `package:resilience/resilience.dart` and `package:test/test.dart` with `hide Retry, Timeout`. A timing assertion runs under fakeAsync or with actions the test completes through a Completer, never on wall-clock sleeps.
Reason: A name collision forces this; timing tests are deterministic with fake_async in four files. hedge_fallback_test violates it today (debt RES-B1).
Evidence: test/*.dart lines 3-5 import lines; test/retry_test.dart:3; test/hedge_fallback_test.dart:6-18
Evidence role: both
Existing violation: resilience-D001

### resilience/RES-10 [SHOULD]
Say in the dartdoc when a policy leaves a future running, since Dart futures cannot be cancelled (Timeout, losing Hedge attempts).
Reason: With resource-holding actions the user must do the cleanup; the two current policies state this explicitly.
Evidence: lib/src/timeout.dart:7-11; lib/src/hedge.dart:22-25
Evidence role: current-pattern
Existing violation: none

### resilience/RES-11 [SHOULD]
Document user callbacks (`retryIf`, `onRetry`, `countAs`, `onStateChange`) with what happens when they throw. A catch-all `catch` in lib is allowed only when the block rethrows.
Reason: Consistent with shared J10/D11: all three catch-all blocks in lib contain a rethrow.
Evidence: lib/src/retry.dart:67-70, 101-107; lib/src/circuit_breaker.dart:77-79, 159-162; lib/src/fallback.dart:48-53
Evidence role: current-pattern
Existing violation: none

## Required verification
- Working directory: repository root; command: dart pub get; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:24.
- Working directory: repository root; command: dart format --output=none --set-exit-if-changed .; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:26.
- Working directory: repository root; command: dart analyze --fatal-infos; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:28.
- Working directory: repository root; command: dart test; conditions: ci.yaml job build; evidence: .github/workflows/ci.yaml:30.
Not verified by the survey:
- I did not run `dart analyze` and `dart test` (read-only); the RES-B1 flake risk was not measured, assessed by reading.
- example/*.dart (4 files, 726 lines) and tool/jitter_figure.dart (252 lines) content was not read; only import lines and print counts.
- Behavior on the web platform (dart2js/dart2wasm): lib uses only dart:async/collection/math but CI does not test it; I could not measure it.
- README.md and AGENTS.md content was not read; AGENTS.md headings: Usage, Contracts, Mistakes, Layout (69 lines).
- GitHub Actions latest run result and pub.dev score (network not permitted).
- Whether the shared detectors (kod-kapisi.py) run on this package: the filter depends on the dart_mcp path (dart-kod-kurallari.md:130-133); I did not open the script.

## Existing debt
The complete register is docs/engineering/debt.json.
- resilience-D001 | medium | test/hedge_fallback_test.dart:37, 49, 62, 69, 81, 97, 181, 186, 201, 265 | time-dependent test (flake risk)
  Fix: Rewrite the tests with `fakeAsync((async) { ... async.elapse(...) })`; keep the Completer-controlled `ControlledAction`.
  Closure: Every timing assertion in hedge_fallback_test runs inside fakeAsync with async.elapse and keeps the Completer-driven ControlledAction. The file contains no wall-clock sleep and the full file passes.
- resilience-D002 | small | lib/src/rate_limiter.dart:110, 133 | duplication
  Fix: A single private helper (`StateError _disposedError()`) or a constant message.
  Closure: rate_limiter.dart builds the disposed StateError in one private helper or one constant message. rate_limiter_test still passes.
