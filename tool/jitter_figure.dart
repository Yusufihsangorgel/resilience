// Draws doc/jitter.svg from delays computed at run time.
//
//   dart run tool/jitter_figure.dart
//   rsvg-convert -w 1600 doc/jitter.svg -o doc/jitter.png
//
// The README says jitter is there so simultaneous clients do not retry in
// lockstep. One client cannot show that: with the jitter dialled off or on,
// its own schedule looks much the same. The claim is about a fleet, so the
// figure simulates one. Every bar is a delay that came back from
// `Backoff.exponential` under the Retry settings the README itself uses, and
// the file is not written when the ordering the picture asserts fails to hold.

import 'dart:io';
import 'dart:math';

import 'package:resilience/resilience.dart';

/// How many clients hit the same dead dependency at t = 0.
const clients = 200;

/// Attempts per client, matching the `Retry` example in the README.
const maxAttempts = 4;

/// The first backoff delay, from that same example.
const initial = Duration(milliseconds: 200);

/// What each further delay is multiplied by.
const factor = 2.0;

/// The width of one histogram column.
const binMs = 25;

/// How far the time axis runs. The last unjittered retry lands at 1400 ms.
const windowMs = 1500;

/// Jitter settings, drawn top to bottom in this order.
const jitters = [0.0, 0.5, 1.0];

/// Seed for the `Random` handed to `Backoff.exponential`.
const seed = 7;

const _binCount = windowMs ~/ binMs;
const _retriesPerClient = maxAttempts - 1;

void main() {
  final fleets = {for (final jitter in jitters) jitter: _simulate(jitter)};
  final problems = _check(fleets);
  if (problems.isNotEmpty) {
    stderr.writeln('refusing to draw a figure that would misstate the run:');
    for (final problem in problems) {
      stderr.writeln('  $problem');
    }
    exitCode = 1;
    return;
  }

  File('doc/jitter.svg').writeAsStringSync(_svg(fleets));

  stdout.writeln('clients             $clients');
  stdout.writeln('retries per client  $_retriesPerClient');
  stdout.writeln('jitter   tallest ${binMs}ms bin   lands at');
  for (final jitter in jitters) {
    final fleet = fleets[jitter]!;
    stdout.writeln(
      '${jitter.toStringAsFixed(1).padRight(9)}'
      '${fleet.peak.toString().padLeft(15)}'
      '${(fleet.peakBin * binMs).toString().padLeft(11)} ms',
    );
  }
  stdout.writeln('wrote doc/jitter.svg');
}

/// Runs one fleet through the shared backoff and buckets the retry times.
///
/// A single [Backoff] serves every client, which is how a shared `Retry`
/// behaves: the README points out that the policy is stateless and reusable.
_Fleet _simulate(double jitter) {
  final backoff = Backoff.exponential(
    initial: initial,
    factor: factor,
    jitter: jitter,
    random: Random(seed),
  );
  final bins = List<int>.filled(_binCount, 0);
  var dropped = 0;
  for (var client = 0; client < clients; client++) {
    var elapsed = Duration.zero;
    for (var attempt = 1; attempt <= _retriesPerClient; attempt++) {
      elapsed += backoff.delay(attempt);
      final bin = elapsed.inMicroseconds ~/ (binMs * 1000);
      if (bin >= _binCount) {
        dropped++;
      } else {
        bins[bin]++;
      }
    }
  }
  return _Fleet(bins, dropped);
}

/// Everything the drawing claims, stated as something that can fail.
List<String> _check(Map<double, _Fleet> fleets) {
  final problems = <String>[];
  for (final jitter in jitters) {
    final fleet = fleets[jitter]!;
    if (fleet.dropped != 0) {
      problems.add(
        'jitter $jitter: ${fleet.dropped} retries land past $windowMs ms, '
        'where the axis cannot show them',
      );
    }
    final expected = clients * _retriesPerClient;
    if (fleet.total != expected) {
      problems.add(
        'jitter $jitter: the bars hold ${fleet.total} retries, not $expected',
      );
    }
  }
  final peaks = [for (final jitter in jitters) fleets[jitter]!.peak];
  if (peaks.first != clients) {
    problems.add(
      'with jitter off the whole fleet should share one bin, but the '
      'tallest holds ${peaks.first} of $clients',
    );
  }
  for (var i = 1; i < peaks.length; i++) {
    if (peaks[i] >= peaks[i - 1]) {
      problems.add(
        'the peak did not drop from jitter ${jitters[i - 1]} (${peaks[i - 1]}) '
        'to jitter ${jitters[i]} (${peaks[i]})',
      );
    }
  }
  return problems;
}

/// One fleet's retries, counted per time bin.
class _Fleet {
  _Fleet(this.bins, this.dropped)
    : peak = bins.fold(0, (a, b) => a > b ? a : b),
      peakBin = bins.indexOf(bins.fold(0, (a, b) => a > b ? a : b)),
      total = bins.fold(0, (a, b) => a + b);

  final List<int> bins;
  final int dropped;
  final int peak;
  final int peakBin;
  final int total;
}

/// Renders a double the way the README writes it: `2` rather than `2.0`.
String _trim(double value) =>
    value == value.roundToDouble() ? '${value.toInt()}' : '$value';

String _svg(Map<double, _Fleet> fleets) {
  const w = 980.0, h = 560.0;
  const left = 210.0, plotW = 730.0;
  const rowH = 100.0, rowGap = 36.0, firstTop = 108.0;
  const colors = ['#F87171', '#38BDF8', '#34D399'];
  const binW = plotW / _binCount;

  double rowTop(int i) => firstTop + i * (rowH + rowGap);
  double baseline(int i) => rowTop(i) + rowH;
  double xAt(num ms) => left + (ms / windowMs) * plotW;

  final grid = StringBuffer();
  final ticks = StringBuffer();
  for (var ms = 0; ms <= windowMs; ms += 250) {
    final gx = xAt(ms).toStringAsFixed(1);
    grid.writeln(
      '<line x1="$gx" y1="${rowTop(0) - 8}" x2="$gx" '
      'y2="${baseline(jitters.length - 1)}" stroke="#1E3A5F" '
      'stroke-width="1"/>',
    );
    ticks.writeln(
      '<text x="$gx" y="${baseline(jitters.length - 1) + 20}" '
      'text-anchor="middle" font-size="12" fill="#64748B">$ms</text>',
    );
  }

  final rows = StringBuffer();
  for (var i = 0; i < jitters.length; i++) {
    final jitter = jitters[i];
    final fleet = fleets[jitter]!;
    final color = colors[i];
    final base = baseline(i);

    for (var bin = 0; bin < _binCount; bin++) {
      final count = fleet.bins[bin];
      if (count == 0) continue;
      var barH = (count / clients) * rowH;
      if (barH < 1) barH = 1;
      rows.writeln(
        '<rect x="${(left + bin * binW + 1.1).toStringAsFixed(2)}" '
        'y="${(base - barH).toStringAsFixed(2)}" '
        'width="${(binW - 2.2).toStringAsFixed(2)}" '
        'height="${barH.toStringAsFixed(2)}" fill="$color"/>',
      );
    }

    rows.writeln(
      '<line x1="$left" y1="$base" x2="${left + plotW}" y2="$base" '
      'stroke="#274b73" stroke-width="1"/>',
    );
    rows.writeln(
      '<text x="${left - 8}" y="${rowTop(i) + 9}" text-anchor="end" '
      'font-size="10" fill="#475569">$clients</text>',
    );
    rows.writeln(
      '<text x="${left - 8}" y="${base + 3}" text-anchor="end" '
      'font-size="10" fill="#475569">0</text>',
    );
    rows.writeln(
      '<text x="48" y="${base - 56}" font-size="15" font-weight="bold" '
      'fill="$color">jitter: ${_trim(jitter)}</text>',
    );
    rows.writeln(
      '<text x="48" y="${base - 34}" font-size="12.5" fill="#94A3B8">'
      'tallest bin ${fleet.peak}</text>',
    );
    rows.writeln(
      '<text x="48" y="${base - 16}" font-size="12.5" fill="#64748B">'
      'of $clients clients</text>',
    );
  }

  return '''
<svg xmlns="http://www.w3.org/2000/svg" width="${w.toInt()}"
     height="${h.toInt()}" viewBox="0 0 ${w.toInt()} ${h.toInt()}"
     font-family="Menlo, monospace">
<rect width="100%" height="100%" fill="#0B1220"/>
<text x="48" y="46" font-size="21" font-weight="bold" fill="#E2E8F0">
  $clients clients fail at the same instant. Where do the retries land?
</text>
<text x="48" y="72" font-size="13" fill="#94A3B8">
  Three jitter settings on one exponential schedule. Rows share a scale;
  a bar counts retries per $binMs ms.
</text>
$grid
$rows
$ticks
<text x="${left + plotW / 2}" y="${baseline(jitters.length - 1) + 44}"
      text-anchor="middle" font-size="12" fill="#64748B">
  milliseconds after the shared failure
</text>
<text x="48" y="${h - 14}" font-size="11.5" fill="#475569">
  Backoff.exponential(initial: ${initial.inMilliseconds} ms, factor: ${_trim(factor)}) under
  Retry(maxAttempts: $maxAttempts), one Random($seed) shared by the fleet.
</text>
</svg>
''';
}
