// One dependency, two paths through it: a 150 ms report render and a 20 ms
// checkout that a customer is waiting on. Which policy protects the checkout,
// and what does it cost?
//
//   a. one bulkhead in front of both paths
//   b. one bulkhead per path, the same total slots
//   c. a saturated bulkhead with no queue
//   d. where a Timeout sits relative to a Bulkhead
//   e. the pipeline from the README, with every policy firing
//
// Everything here is local: the dependency is Future.delayed and the failures
// are scripted. There is no network, no server and no file to set up. Every
// number below was measured by the run that printed it.
//
//   dart run example/resilience_example.dart
import 'dart:async';

import 'package:resilience/resilience.dart';

/// Thrown by the fake upstream when it is unavailable.
final class ServiceUnavailableException implements Exception {
  @override
  String toString() => 'ServiceUnavailableException: 503 from upstream';
}

/// The one dependency both paths of the app go through.
final class Downstream {
  int _inFlight = 0;

  /// How many calls are running inside the dependency right now.
  ///
  /// No policy can see this number. Scene (d) is about the gap between it and
  /// what a [Bulkhead] believes.
  int get inFlight => _inFlight;

  /// Renders a report. Slow on purpose.
  Future<String> renderReport(int id) =>
      _run(const Duration(milliseconds: 150), 'report $id');

  /// Takes a payment. Fast, and the one somebody is waiting on.
  Future<String> checkout(int id) =>
      _run(const Duration(milliseconds: 20), 'checkout $id');

  Future<String> _run(Duration cost, String label) async {
    _inFlight++;
    try {
      await Future<void>.delayed(cost);
      return label;
    } finally {
      _inFlight--;
    }
  }
}

/// A fake upstream that answers from a fixed script, which keeps the run
/// repeatable.
final class ScriptedUpstream {
  /// Creates an upstream that follows [script], then stays healthy.
  ScriptedUpstream(this.script);

  /// The scripted responses, consumed in order.
  final List<({Duration after, bool fails})> script;

  int _index = 0;

  /// How many times the action has actually run.
  int get calls => _index;

  /// Answers the next scripted response.
  Future<String> get(String path) async {
    final step = _index < script.length
        ? script[_index]
        : (after: const Duration(milliseconds: 20), fails: false);
    _index++;
    await Future<void>.delayed(step.after);
    if (step.fails) {
      throw ServiceUnavailableException();
    }
    return '{"path": "$path", "ok": true}';
  }
}

/// What one report-versus-checkout race measured.
typedef _Race = ({List<int> waits, int queuedOnArrival, int reportsMs});

/// What one Timeout-versus-Bulkhead ordering measured.
typedef _GaveUp = ({int ms, int active, int queued, int inFlight, int drainMs});

/// Starts 24 reports, then five checkouts 10 ms behind them, and reports how
/// long each checkout waited for a slot.
///
/// Pass the same bulkhead twice for a shared pool, or two for isolation.
Future<_Race> _race(
  Downstream down,
  Bulkhead reportPool,
  Bulkhead checkoutPool,
) async {
  final clock = Stopwatch()..start();
  final reports = <Future<String>>[];
  for (var i = 0; i < 24; i++) {
    reports.add(reportPool.execute(() => down.renderReport(i)));
  }
  final reportsDone = Future.wait(reports).then((_) => clock.elapsed);

  await Future<void>.delayed(const Duration(milliseconds: 10));
  final queuedOnArrival = checkoutPool.queueLength;

  final waits = <int>[];
  final checkouts = <Future<String>>[];
  for (var i = 0; i < 5; i++) {
    final submitted = clock.elapsedMilliseconds;
    checkouts.add(
      checkoutPool.execute(() {
        // This runs the moment the bulkhead admits the call. The difference is
        // time spent queueing, not time spent working.
        waits.add(clock.elapsedMilliseconds - submitted);
        return down.checkout(i);
      }),
    );
  }

  await Future.wait(checkouts);
  final reportsMs = (await reportsDone).inMilliseconds;
  waits.sort();
  return (waits: waits, queuedOnArrival: queuedOnArrival, reportsMs: reportsMs);
}

/// Sends four callers at a 150 ms dependency behind a 40 ms timeout, then asks
/// the bulkhead and the dependency what each of them believes afterwards.
Future<_GaveUp> _giveUp(
  Downstream down, {
  required bool bulkheadOutside,
}) async {
  const timeout = Timeout(Duration(milliseconds: 40));
  final bulkhead = Bulkhead(maxConcurrent: 2, maxQueued: 8);
  final pipeline = ResiliencePipeline(
    bulkheadOutside ? [bulkhead, timeout] : [timeout, bulkhead],
  );

  final clock = Stopwatch()..start();
  Future<void> caller(int id) async {
    try {
      await pipeline.execute(() => down.renderReport(id));
    } on TimeoutException {
      // Expected. The scene is about what the timeout left behind.
    }
  }

  await Future.wait([for (var id = 0; id < 4; id++) caller(id)]);
  final settled = clock.elapsedMilliseconds;
  final active = bulkhead.activeCount;
  final queued = bulkhead.queueLength;
  final inFlight = down.inFlight;
  while (down.inFlight > 0) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return (
    ms: settled,
    active: active,
    queued: queued,
    inFlight: inFlight,
    drainMs: clock.elapsedMilliseconds - settled,
  );
}

Future<void> main() async {
  final down = Downstream();
  print('');
  print('A 150 ms report render and a 20 ms checkout share one dependency.');
  print('');

  // (a) One pool in front of everything. The reports fill it, and the checkout
  // takes its place at the back of the same queue.
  final shared = Bulkhead(maxConcurrent: 8, maxQueued: 128);
  final pooled = await _race(down, shared, shared);
  print('a. one bulkhead for both paths, maxConcurrent 8');
  print(
    '   the checkout arrived behind ${pooled.queuedOnArrival} queued reports',
  );
  print(
    '   five checkouts waited ${pooled.waits.join(' ')} ms '
    'to do 20 ms of work each',
  );
  print('   the reports finished in ${pooled.reportsMs} ms');
  print('');

  // (b) The same eight slots, split. Nothing about the dependency changed.
  final reportPool = Bulkhead(maxConcurrent: 6, maxQueued: 128);
  final checkoutPool = Bulkhead(maxConcurrent: 2, maxQueued: 16);
  final split = await _race(down, reportPool, checkoutPool);
  print('b. one bulkhead per path, 6 + 2, the same eight slots');
  print(
    '   the checkout arrived behind ${split.queuedOnArrival} queued calls '
    'in its own bulkhead',
  );
  print(
    '   five checkouts waited ${split.waits.join(' ')} ms '
    '(two slots: they go in pairs)',
  );
  print('   the reports finished in ${split.reportsMs} ms');
  print(
    '   isolation gave the checkout back '
    '${pooled.waits.last - split.waits.last} ms and cost the reports '
    '${split.reportsMs - pooled.reportsMs} ms',
  );
  print('');

  // (c) maxQueued defaults to 0. That is a decision, not an oversight.
  final tight = Bulkhead(maxConcurrent: 2);
  final rejectClock = Stopwatch()..start();
  var accepted = 0;
  var rejected = 0;
  var rejectedAtMs = 0;
  var activeWhenRejected = 0;
  String? reason;
  Future<void> attempt(int id) async {
    try {
      await tight.execute(() => down.checkout(id));
      accepted++;
    } on BulkheadRejectedException catch (error) {
      rejected++;
      // Read the clock here, not after the scene: the whole point is how
      // little a rejection costs the caller.
      rejectedAtMs = rejectClock.elapsedMilliseconds;
      activeWhenRejected = tight.activeCount;
      reason ??= '$error';
    }
  }

  await Future.wait([for (var id = 0; id < 6; id++) attempt(id)]);
  print('c. Bulkhead(maxConcurrent: 2) with the default maxQueued of 0');
  print(
    '   6 calls at once: $accepted ran, $rejected were turned away after '
    '$rejectedAtMs ms with $activeWhenRejected slots busy',
  );
  print('   $reason');
  print(
    '   scene (a) had the queue depth to wait instead, and paid '
    '${pooled.waits.last} ms for it',
  );
  print('');

  // (d) Both orders compile and both are legal. They protect different things.
  final outside = await _giveUp(down, bulkheadOutside: true);
  final inside = await _giveUp(down, bulkheadOutside: false);
  print(
    'd. Bulkhead(maxConcurrent: 2), Timeout(40 ms), 4 callers, 150 ms of work',
  );
  print(
    '   [bulkhead, timeout]  gave up at ${outside.ms} ms   '
    'bulkhead ${outside.active} busy, ${outside.queued} queued   '
    '${outside.inFlight} calls ran on for ${outside.drainMs} ms',
  );
  print(
    '   [timeout, bulkhead]  gave up at ${inside.ms} ms   '
    'bulkhead ${inside.active} busy, ${inside.queued} queued   '
    '${inside.inFlight} calls ran on for ${inside.drainMs} ms',
  );
  print(
    '   the outer position bounds how many callers wait, the inner one how '
    'much work runs',
  );
  print('');

  // (e) The pipeline from the README. Retry outside the breaker, Timeout
  // inside it so a half-open trial always settles, limiter innermost.
  final api = ScriptedUpstream([
    (after: const Duration(milliseconds: 10), fails: true),
    (after: const Duration(milliseconds: 500), fails: false),
    (after: const Duration(milliseconds: 10), fails: true),
  ]);
  var retries = 0;
  final breaker = CircuitBreaker(
    failureThreshold: 3,
    resetTimeout: const Duration(milliseconds: 400),
    onStateChange: (state) => print('   breaker -> ${state.name}'),
  );
  final limiter = RateLimiter(
    maxPermits: 4,
    per: const Duration(milliseconds: 120),
    maxQueueLength: 32,
  );
  final pipeline = ResiliencePipeline([
    Retry(
      maxAttempts: 3,
      backoff: const Backoff.fixed(Duration(milliseconds: 40)),
      onRetry: (event) {
        retries++;
        print(
          '   attempt ${event.attempt} failed (${event.error}), '
          'next in ${event.nextDelay.inMilliseconds} ms',
        );
      },
    ),
    breaker,
    const Timeout(Duration(milliseconds: 250)),
    limiter,
  ]);

  print(
    'e. Retry(3) -> CircuitBreaker(3) -> Timeout(250 ms) -> '
    'RateLimiter(4 per 120 ms)',
  );
  try {
    await pipeline.execute(() => api.get('/users/42'));
  } on ServiceUnavailableException catch (error) {
    print(
      '   request 1 gave up after ${api.calls} upstream calls and $retries '
      'retries: $error',
    );
  }

  final callsBefore = api.calls;
  final retriesBefore = retries;
  try {
    await pipeline.execute(() => api.get('/users/42'));
  } on CircuitOpenException catch (error) {
    print(
      '   request 2 cost ${api.calls - callsBefore} upstream calls and '
      '${retries - retriesBefore} retries: open for another '
      '${error.retryAfter.inMilliseconds} ms',
    );
  }
  print('   only time reopens a circuit, and the default retryIf knows it');

  await Future<void>.delayed(const Duration(milliseconds: 500));
  final body = await pipeline.execute(() => api.get('/users/42'));
  print('   request 3, after the reset timeout: $body');

  // Let the bucket refill so the burst starts from a known state.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final burstClock = Stopwatch()..start();
  final starts = <int>[];
  final burst = <Future<String>>[];
  for (var id = 0; id < 8; id++) {
    burst.add(
      pipeline.execute(() {
        starts.add(burstClock.elapsedMilliseconds);
        return api.get('/orders/$id');
      }),
    );
  }
  await Future.wait(burst);
  print(
    '   8 requests at once started at '
    '${starts.map((ms) => '+$ms').join(' ')} ms',
  );
  print('   four tokens were in the bucket, then one every 30 ms');
  limiter.dispose();
  print('');
}
