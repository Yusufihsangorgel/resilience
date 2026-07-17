import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:resilience/resilience.dart';
import 'package:test/test.dart' hide Retry, Timeout;

void main() {
  group('Timeout', () {
    test('returns the result when the action finishes in time', () {
      fakeAsync((async) {
        const timeout = Timeout(Duration(seconds: 1));
        Object? result;
        unawaited(
          timeout.execute(() async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            return 'fast enough';
          }).then((value) => result = value),
        );
        async.elapse(const Duration(milliseconds: 500));
        expect(result, 'fast enough');
      });
    });

    test('throws TimeoutException when the action takes too long', () {
      fakeAsync((async) {
        const timeout = Timeout(Duration(seconds: 1));
        final never = Completer<String>();
        Object? error;
        unawaited(
          timeout.execute(() => never.future).then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          ),
        );
        async.elapse(const Duration(milliseconds: 999));
        expect(error, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(error, isA<TimeoutException>());
      });
    });

    test('discards the late result of a timed out action', () {
      fakeAsync((async) {
        const timeout = Timeout(Duration(seconds: 1));
        final late = Completer<String>();
        Object? error;
        unawaited(
          timeout.execute(() => late.future).then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          ),
        );
        async.elapse(const Duration(seconds: 1));
        expect(error, isA<TimeoutException>());

        // The action completes after the timeout; nothing observes it and
        // no unhandled error escapes.
        late.complete('too late');
        async.flushMicrotasks();
      });
    });

    test('propagates the action error when it fails in time', () {
      fakeAsync((async) {
        const timeout = Timeout(Duration(seconds: 1));
        Object? error;
        unawaited(
          timeout.execute<void>(() async {
            throw const FormatException('boom');
          }).then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          ),
        );
        async.flushMicrotasks();
        expect(error, isFormatException);
      });
    });
  });
}
