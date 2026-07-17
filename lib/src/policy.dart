/// A resilience policy that controls how an asynchronous action is executed.
///
/// Implementations decide whether to run the action, run it again, delay it,
/// or fail fast. Policies are composable: see `ResiliencePipeline` for
/// combining several policies around a single action.
abstract interface class Policy {
  /// Runs [action] under this policy and returns its result.
  ///
  /// The policy may invoke [action] zero times (for example a circuit
  /// breaker that is open), once, or several times (for example a retry).
  Future<T> execute<T>(Future<T> Function() action);
}
