import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

/// A policy that records when it is entered, for asserting wrap order.
class RecordingPolicy implements Policy {
  RecordingPolicy(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  Future<T> execute<T>(Future<T> Function() action) async {
    log.add('$name:enter');
    try {
      return await action();
    } finally {
      log.add('$name:exit');
    }
  }
}

void main() {
  group('ResiliencePipeline', () {
    test('an empty pipeline runs the action unchanged', () async {
      final pipeline = ResiliencePipeline([]);
      expect(await pipeline.execute(() async => 'plain'), 'plain');
    });

    test('wraps policies from the outside in, first policy outermost',
        () async {
      final log = <String>[];
      final pipeline = ResiliencePipeline([
        RecordingPolicy('outer', log),
        RecordingPolicy('middle', log),
        RecordingPolicy('inner', log),
      ]);
      await pipeline.execute(() async => log.add('action'));
      expect(log, [
        'outer:enter',
        'middle:enter',
        'inner:enter',
        'action',
        'inner:exit',
        'middle:exit',
        'outer:exit',
      ]);
    });

    test('a retry outside a circuit breaker retries the open rejection',
        () async {
      var calls = 0;
      final events = <RetryEvent>[];
      final breaker = CircuitBreaker(failureThreshold: 1);
      final pipeline = ResiliencePipeline([
        Retry(maxAttempts: 3, onRetry: events.add),
        breaker,
      ]);

      await expectLater(
        pipeline.execute<void>(() async {
          calls++;
          throw const FormatException('boom');
        }),
        throwsA(isA<CircuitOpenException>()),
      );

      // The first attempt failed and opened the breaker; the remaining
      // attempts were rejected without reaching the action.
      expect(calls, 1);
      expect(breaker.state, CircuitState.open);
      expect(events, hasLength(2));
      expect(events[0].error, isFormatException);
      expect(events[1].error, isA<CircuitOpenException>());
    });

    test(
        'a circuit breaker outside a retry counts one exhausted retry as '
        'one failure', () async {
      var calls = 0;
      final breaker = CircuitBreaker(failureThreshold: 2);
      final pipeline = ResiliencePipeline([
        breaker,
        Retry(maxAttempts: 3),
      ]);

      await expectLater(
        pipeline.execute<void>(() async {
          calls++;
          throw const FormatException('boom');
        }),
        throwsFormatException,
      );

      // Three attempts inside the retry, one counted failure outside it.
      expect(calls, 3);
      expect(breaker.state, CircuitState.closed);
    });

    test('a pipeline is itself a policy and can be nested', () async {
      final log = <String>[];
      final inner = ResiliencePipeline([RecordingPolicy('inner', log)]);
      final outer = ResiliencePipeline([RecordingPolicy('outer', log), inner]);
      expect(await outer.execute(() async => 7), 7);
      expect(log, ['outer:enter', 'inner:enter', 'inner:exit', 'outer:exit']);
    });

    test('does not reflect later mutations of the policy list', () async {
      final log = <String>[];
      final policies = <Policy>[RecordingPolicy('kept', log)];
      final pipeline = ResiliencePipeline(policies);
      policies.add(RecordingPolicy('added-later', log));
      await pipeline.execute(() async => 0);
      expect(log, ['kept:enter', 'kept:exit']);
    });
  });
}
