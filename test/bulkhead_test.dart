import 'dart:async';

import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

void main() {
  group('Bulkhead', () {
    test('runs at most maxConcurrent actions at the same time', () async {
      final bulkhead = Bulkhead(maxConcurrent: 2, maxQueued: 10);
      var active = 0;
      var peak = 0;
      final gate = Completer<void>();

      final futures = List.generate(5, (_) {
        return bulkhead.execute(() async {
          active++;
          if (active > peak) {
            peak = active;
          }
          await gate.future;
          active--;
        });
      });

      await Future<void>.delayed(Duration.zero);
      expect(active, 2);
      expect(bulkhead.activeCount, 2);
      expect(bulkhead.queueLength, 3);

      gate.complete();
      await Future.wait(futures);
      expect(peak, 2);
      expect(bulkhead.activeCount, 0);
      expect(bulkhead.queueLength, 0);
    });

    test('runs queued calls in FIFO order once slots free up', () async {
      final bulkhead = Bulkhead(maxConcurrent: 1, maxQueued: 3);
      final order = <int>[];
      final gate = Completer<void>();

      final first = bulkhead.execute(() async {
        await gate.future;
        order.add(0);
      });
      final queued = List.generate(3, (i) {
        return bulkhead.execute(() async => order.add(i + 1));
      });

      gate.complete();
      await Future.wait([first, ...queued]);
      expect(order, [0, 1, 2, 3]);
    });

    test('rejects calls when the queue is full', () async {
      final bulkhead = Bulkhead(maxConcurrent: 1, maxQueued: 1);
      final gate = Completer<String>();

      final running = bulkhead.execute(() => gate.future);
      final queued = bulkhead.execute(() async => 'queued');

      var rejectedCalls = 0;
      await expectLater(
        bulkhead.execute(() async => rejectedCalls++),
        throwsA(
          isA<BulkheadRejectedException>().having(
            (e) => e.toString(),
            'toString',
            contains('maxQueued: 1'),
          ),
        ),
      );
      expect(rejectedCalls, 0);

      gate.complete('done');
      expect(await running, 'done');
      expect(await queued, 'queued');
    });

    test('rejects immediately when saturated and maxQueued is 0', () async {
      final bulkhead = Bulkhead(maxConcurrent: 1);
      final gate = Completer<void>();
      final running = bulkhead.execute(() => gate.future);

      await expectLater(
        bulkhead.execute(() async => 'nope'),
        throwsA(isA<BulkheadRejectedException>()),
      );

      gate.complete();
      await running;
    });

    test('releases the slot when the action throws', () async {
      final bulkhead = Bulkhead(maxConcurrent: 1);
      await expectLater(
        bulkhead.execute<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(await bulkhead.execute(() async => 'recovered'), 'recovered');
      expect(bulkhead.activeCount, 0);
    });

    test('hands a freed slot to the oldest waiter, not a new call', () async {
      final bulkhead = Bulkhead(maxConcurrent: 1, maxQueued: 1);
      final order = <String>[];
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();

      final first = bulkhead.execute(() => gate1.future);
      final waiter = bulkhead.execute(() {
        order.add('waiter-start');
        return gate2.future;
      });

      gate1.complete();
      await first;

      // The slot was transferred to the waiter synchronously when the
      // first action finished, even though the waiter itself has not
      // resumed yet.
      expect(order, isEmpty);
      expect(bulkhead.activeCount, 1);
      expect(bulkhead.queueLength, 0);

      // A new call arriving in this window cannot steal the slot; it
      // queues behind the waiter.
      final latecomer = bulkhead.execute(() async => order.add('latecomer'));
      expect(bulkhead.queueLength, 1);

      await Future<void>.delayed(Duration.zero);
      expect(order, ['waiter-start']);

      gate2.complete();
      await Future.wait([waiter, latecomer]);
      expect(order, ['waiter-start', 'latecomer']);
    });

    test('rejects invalid arguments', () {
      expect(() => Bulkhead(maxConcurrent: 0), throwsArgumentError);
      expect(
        () => Bulkhead(maxConcurrent: 1, maxQueued: -1),
        throwsArgumentError,
      );
    });
  });
}
