// What hedging buys, measured against not hedging.
//
//   dart run example/hedge_tail_latency.dart
//
// `Hedge` is the one policy in this package that a retry cannot stand in for,
// and the example directory named it in prose without ever running it. The
// difference is worth a number.
//
// A retry starts after an attempt has failed or timed out, so by the time it
// helps, the latency is already spent. Hedging starts a second attempt while
// the first is still in flight. Nothing has to fail for it to work, which is
// why it is the tool for a backend that is healthy and occasionally slow --
// a stalled connection, an unlucky GC pause, a node about to move.
//
// The backend below is fake and deterministic: nineteen calls in twenty answer
// in 20 ms and the twentieth takes 600. No network, same numbers every run.
import 'dart:async';

import 'package:resilience/resilience.dart';

/// A service that is fast except when it is not.
///
/// The slow calls are picked by index rather than at random, so the two
/// columns below are comparing the same requests.
class FlakyService {
  int _calls = 0;
  final _attemptsPerRequest = <int, int>{};

  /// Which of the caller's requests are the slow ones.
  ///
  /// Picked by index rather than at random so both columns below are timing
  /// the same requests.
  static bool isSlow(int request) => request % 20 == 7;

  /// How many times the service was actually hit, hedges included.
  int get calls => _calls;

  Future<String> fetch(int request) async {
    _calls++;
    final attempt = (_attemptsPerRequest[request] ?? 0) + 1;
    _attemptsPerRequest[request] = attempt;

    // Only the *first* attempt at a slow request is slow. That is the model
    // hedging is built for: what stalled is the connection or the node, not
    // the work, so a second copy on a fresh connection comes back at the
    // normal speed. If the slowness were the work itself, hedging would buy
    // nothing and only add load.
    final slow = isSlow(request) && attempt == 1;
    await Future<void>.delayed(Duration(milliseconds: slow ? 600 : 20));
    return 'response $request';
  }
}

Future<({int p50, int p99, int max, int calls})> run(
  Policy? policy,
  int requests,
) async {
  final service = FlakyService();
  final timings = <int>[];
  for (var i = 0; i < requests; i++) {
    final watch = Stopwatch()..start();
    Future<String> action() => service.fetch(i);
    await (policy == null ? action() : policy.execute(action));
    watch.stop();
    timings.add(watch.elapsedMilliseconds);
  }
  timings.sort();
  return (
    p50: timings[(timings.length * 0.50).floor()],
    p99: timings[(timings.length * 0.99).floor()],
    max: timings.last,
    calls: service.calls,
  );
}

Future<void> main() async {
  const requests = 100;

  print('');
  print(
    '$requests requests. One in twenty stalls for 600 ms; the rest take 20.',
  );
  print('');

  final plain = await run(null, requests);
  // Sitting just above the fast path, which is where a hedge delay belongs:
  // near p95, not near the median, or every call is doubled.
  final hedged = await run(
    Hedge(delay: const Duration(milliseconds: 50)),
    requests,
  );

  print(
    '${''.padRight(12)}${'p50'.padLeft(7)}${'p99'.padLeft(7)}'
    '${'max'.padLeft(7)}${'backend calls'.padLeft(16)}',
  );
  print('  ${'-' * 47}');
  for (final (label, r) in [('no policy', plain), ('hedged', hedged)]) {
    print(
      '${label.padRight(12)}${'${r.p50} ms'.padLeft(7)}'
      '${'${r.p99} ms'.padLeft(7)}${'${r.max} ms'.padLeft(7)}'
      '${r.calls.toString().padLeft(16)}',
    );
  }

  final saved = plain.max - hedged.max;
  print('');
  print('The median did not move: a fast call finishes long before the hedge');
  print('would start, so it never starts. The tail lost $saved ms, and the');
  print('cost was ${hedged.calls - plain.calls} extra calls out of $requests.');
  print('');
  print('That trade is the whole decision. Put the delay near your p95 and');
  print('you pay for the few percent that are slow; put it near your median');
  print('and you double the load on a backend to fix a problem it may not');
  print('have. And hedge reads, not writes -- two copies of a POST that');
  print('creates an order create two orders.');
}
