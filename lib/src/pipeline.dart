import 'policy.dart';

/// Combines several policies into one, wrapping them from the outside in.
///
/// The first policy in the list is the outermost one. For example:
///
/// ```dart
/// final pipeline = ResiliencePipeline([retry, breaker, timeout]);
/// ```
///
/// behaves like:
///
/// ```dart
/// retry.execute(() => breaker.execute(() => timeout.execute(action)));
/// ```
///
/// Order matters. With a retry outside a circuit breaker, the retry also
/// retries the breaker's own rejections. With the breaker outside, one
/// exhausted retry counts as a single failure toward opening the circuit.
///
/// A pipeline is itself a [Policy], so pipelines can be nested.
final class ResiliencePipeline implements Policy {
  /// Creates a pipeline from [policies], outermost first.
  ///
  /// The list is copied; later changes to it do not affect the pipeline.
  /// An empty list produces a pipeline that runs actions unchanged.
  ResiliencePipeline(List<Policy> policies)
    : _policies = List.unmodifiable(policies);

  final List<Policy> _policies;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    var wrapped = action;
    for (final policy in _policies.reversed) {
      final inner = wrapped;
      wrapped = () => policy.execute(inner);
    }
    return wrapped();
  }
}
