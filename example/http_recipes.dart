// The ten lines that wrap dart:io HttpClient.
//
// The question this package exists to answer is "make this API call
// resilient", and the answer is not another policy abstraction — it is this
// wiring. dart:io HttpClient does not throw on a 503; Retry and the breaker
// only see exceptions, so the wrapper has to throw. The policies that hold
// state live next to the client, not inside the method that uses them.
//
//   dart run example/http_recipes.dart
//
// Everything here is local: HttpServer.bind on loopback, a scripted sequence
// of 503s then 200s. There is no network beyond this process.
//
// The dio shape is the same and is sketched in the README. It is not compiled
// here: this package does not depend on dio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:resilience/resilience.dart';

void _onRetry(RetryEvent event) {
  print(
    '   attempt ${event.attempt} failed (${event.error}), '
    'next in ${event.nextDelay.inMilliseconds} ms',
  );
}

void _onStateChange(CircuitState state) => print('   breaker -> ${state.name}');

/// An [HttpClient] wrapped in the pipeline from the README.
///
/// Policies are fields, created once with this object. Constructing
/// [CircuitBreaker] inside [get] would reset the failure count on every
/// call, so consecutive failures would never accumulate and the breaker
/// would never open. The same is true of [RateLimiter] and [Bulkhead]: a
/// new instance per request is a full bucket and a free slot.
final class ResilientClient {
  /// Opens a pipeline around [client] for the server at [base].
  ///
  /// Create one instance per protected dependency and reuse it. Retry
  /// outside the breaker so an open circuit fails fast; timeout inside it
  /// so a half-open trial always settles.
  ResilientClient(
    this._client,
    this._base, {
    void Function(CircuitState state)? onStateChange,
    void Function(RetryEvent event)? onRetry,
  }) : _breaker = CircuitBreaker(
         failureThreshold: 3,
         resetTimeout: const Duration(milliseconds: 400),
         onStateChange: onStateChange,
       ) {
    _pipeline = ResiliencePipeline([
      Retry(
        maxAttempts: 3,
        backoff: const Backoff.fixed(Duration(milliseconds: 40)),
        onRetry: onRetry,
      ),
      _breaker,
      const Timeout(Duration(milliseconds: 250)),
    ]);
  }

  final HttpClient _client;
  final Uri _base;
  final CircuitBreaker _breaker;
  late final ResiliencePipeline _pipeline;

  /// The breaker's current state.
  CircuitState get state => _breaker.state;

  /// GET [path] through the pipeline.
  ///
  /// The request starts inside the thunk. Passing an already-started
  /// [Future] would make retry replay a completed future.
  Future<String> get(String path) {
    return _pipeline.execute(() => _send(path));
  }

  Future<String> _send(String path) async {
    final url = _base.replace(path: path);
    final request = await _client.getUrl(url);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    // dart:io HttpClient does not throw on a 503. Retry and the breaker
    // only see exceptions, so a non-2xx has to become one.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('${response.statusCode} from $path');
    }
    return body;
  }
}

/// Remaining status codes for a path, then [orElse] forever.
final class _Script {
  _Script(this._codes, {this.orElse = HttpStatus.ok});

  final List<int> _codes;
  final int orElse;
  var _index = 0;

  int next() {
    if (_index < _codes.length) {
      return _codes[_index++];
    }
    return orElse;
  }
}

/// Serves a scripted status per path and counts hits, so an open circuit
/// can be shown as a call that never reached the server.
final class _Handler {
  _Handler(this._scripts);

  final Map<String, _Script> _scripts;
  final Map<String, int> _hits = {};

  int hitsOn(String path) => _hits[path] ?? 0;

  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    _hits.update(path, (n) => n + 1, ifAbsent: () => 1);
    final status = _scripts[path]?.next() ?? HttpStatus.notFound;
    print('   server  GET $path  -> $status');
    request.response.statusCode = status;
    request.response.write(
      status == HttpStatus.ok ? '{"ok":true}' : 'unavailable',
    );
    await request.response.close();
  }
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final handler = _Handler({
    '/recover': _Script([
      HttpStatus.serviceUnavailable,
      HttpStatus.serviceUnavailable,
    ]),
    '/down': _Script(const [], orElse: HttpStatus.serviceUnavailable),
  });
  server.listen((request) {
    unawaited(handler.handle(request));
  });

  final client = HttpClient();
  final base = Uri(
    scheme: 'http',
    host: server.address.address,
    port: server.port,
  );

  // Constructed once, next to the client. If CircuitBreaker (or a
  // ResiliencePipeline that constructs one) lived inside get(), every
  // call would get a fresh closed breaker: consecutive failures would
  // never accumulate, the breaker would never open, and a down
  // dependency would keep being hit.
  final recovering = ResilientClient(
    client,
    base,
    onRetry: _onRetry,
    onStateChange: _onStateChange,
  );
  final down = ResilientClient(
    client,
    base,
    onRetry: _onRetry,
    onStateChange: _onStateChange,
  );

  print('');
  print('Wrapping dart:io HttpClient. Policies live on ResilientClient,');
  print('created once. Constructing the breaker inside get() resets it on');
  print(
    'every call; consecutive failures never accumulate and it never opens.',
  );
  print('');

  try {
    print('a. the server 503s twice, then 200s; retry recovers');
    final body = await recovering.get('/recover');
    print('   ok: $body');
    print(
      '   ${handler.hitsOn('/recover')} hits, circuit ${recovering.state.name}',
    );
    print('');

    print('b. the server stays down; the breaker opens');
    try {
      await down.get('/down');
    } on HttpException catch (error) {
      print(
        '   request 1 gave up after ${handler.hitsOn('/down')} hits: $error',
      );
    }

    final hitsBefore = handler.hitsOn('/down');
    try {
      await down.get('/down');
    } on CircuitOpenException {
      print(
        '   request 2 cost ${handler.hitsOn('/down') - hitsBefore} hits: '
        'CircuitOpenException (failed fast, no HTTP call)',
      );
    }
    print('   only time reopens a circuit, and the default retryIf knows it');
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  print('');
}
