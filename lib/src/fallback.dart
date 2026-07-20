import 'dart:async';

import 'policy.dart';

/// Runs [action] under [policy] and returns a substitute value if it still
/// fails, so a caller sees degraded data rather than an exception.
///
/// The other policies decide how hard to try; this decides what to show when
/// trying did not work. Serve the last cached response, an empty list, a
/// default configuration: whatever keeps the screen useful while the backend
/// is not.
///
/// ```dart
/// final pipeline = ResiliencePipeline([retry, breaker, timeout]);
///
/// final rates = await withFallback(
///   pipeline,
///   () => api.fetchRates(),
///   fallback: (error, stackTrace) => cache.lastRates,
/// );
/// ```
///
/// [shouldHandle] narrows which failures get a substitute; without it every
/// error does. Return false for the ones that should still reach the caller,
/// such as a bad request that a retry would never have fixed either:
///
/// ```dart
/// fallback: (e, s) => cache.lastRates,
/// shouldHandle: (e) => e is! ArgumentError,
/// ```
///
/// This is a function rather than a [Policy] on purpose. A fallback belongs
/// outside everything else, because it swallows the error: put one inside a
/// retry and the retry sees a successful call and never runs again, and put
/// one inside a circuit breaker and the breaker never learns the call is
/// failing. Taking the policy as an argument makes the outermost position the
/// only one available, and keeps the substitute typed to the action's result
/// instead of a value a generic policy would have to produce out of nothing.
///
/// An error thrown by [fallback] itself propagates, since there is nothing
/// left to fall back to.
Future<T> withFallback<T>(
  Policy policy,
  Future<T> Function() action, {
  required FutureOr<T> Function(Object error, StackTrace stackTrace) fallback,
  bool Function(Object error)? shouldHandle,
}) async {
  try {
    return await policy.execute(action);
  } catch (error, stackTrace) {
    if (shouldHandle != null && !shouldHandle(error)) rethrow;
    return await fallback(error, stackTrace);
  }
}
