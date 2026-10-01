import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:flutter/foundation.dart';

part 'live.dart';

class ThreadRipperStats {
  const ThreadRipperStats({
    this.activeThreads = 0,
    this.threadLimit = 0,
    this.bytesPerSecond = 0,
    this.downloadedBytes = 0,
    this.retries = 0,
    this.fallbacks = 0,
    this.lastHost = '',
    this.status = '等待播放',
  });
  final int activeThreads;
  final int threadLimit;
  final int bytesPerSecond;
  final int downloadedBytes;
  final int retries;
  final int fallbacks;
  final String lastHost;
  final String status;
}

/// Loopback transport for the shared mpv player on all five native platforms.
/// No signed URL is exposed in the local URL or accepted from HTTP clients.
class ThreadRipperProxy {
  ThreadRipperProxy({
    required this.options,
    required this.userAgent,
    required this.referer,
    this.upstreamProxy,
    this.onFallback,
    this.clientFactory,
    this.chunkBytes = 256 * 1024,
    this.firstByteTimeout = const Duration(milliseconds: 5500),
    this.stallTimeout = const Duration(seconds: 4),
    this.attemptTimeout = const Duration(seconds: 15),
  }) : assert(chunkBytes > 0) {
    _pool = _TransferPool(() => _limit);
  }

  final ThreadRipperOptions options;
  final String userAgent;
  final String referer;
  final String? upstreamProxy;
  final VoidCallback? onFallback;

  /// Allows deterministic transport tests without contacting Bilibili.
  final HttpClient Function()? clientFactory;
  final int chunkBytes;
  final Duration firstByteTimeout;
  final Duration stallTimeout;
  final Duration attemptTimeout;
  final stats = ValueNotifier(const ThreadRipperStats());
  final _assets = <String, _Asset>{};
  final _transfers = <_Transfer>{};
  final _health = <String, _RouteHealth>{};
  final _clock = Stopwatch()..start();
  late final _TransferPool _pool;
  HttpServer? _server;
  Timer? _statsTimer;
  bool _closed = false;
  late final _concurrency = ThreadRipperConcurrency(
    concurrency: options.concurrency,
  );
  int get _limit => _concurrency.limit;
  int _bytes = 0;
  int _sampleBytes = 0;
  int _sampleAt = 0;
  int _retries = 0;
  int _fallbacks = 0;
  int _sequence = 0;
  int _rotation = 0;
  String _lastHost = '';
  String _status = '等待播放';
  late final String _token = List.generate(
    24,
    (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> start() async {
    if (_closed) throw StateError('Transport closed');
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)));
    _sampleAt = _clock.elapsedMilliseconds;
    _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _publish();
      _pruneLiveAssets();
    });
  }

  String _register(_Asset asset, String extension) {
    if (_closed || _server == null) throw StateError('Transport unavailable');
    final key = '/$_token/${_sequence++}$extension';
    _assets[key] = asset;
    return 'http://127.0.0.1:${_server!.port}$key';
  }

  /// Only trusted callers register upstream URLs; the HTTP server has no URL input.
  String addVod(List<Uri> candidates, {List<Uri>? fallbackUrls}) =>
      _register(_VodAsset(candidates, fallbackUrls ?? candidates), '.m4s');

  String addLive(List<Uri> candidates) => _addLive(candidates);

  String wrapMedia(
    String url, {
    Iterable<String> alternatives = const [],
    bool live = false,
    bool rewriteCdn = true,
  }) {
    final candidates = rewriteCdn
        ? ThreadRipperCdn.resolve([url, ...alternatives], options, live: live)
        : [
            for (final value in [url, ...alternatives])
              if (Uri.tryParse(value) case final uri?
                  when ThreadRipperCdn.isMedia(uri))
                uri,
          ];
    if (candidates.isEmpty) {
      if (live) _status = '当前直播路线未启用加速，请选择 HLS 分片路线';
      return url;
    }
    if (live) return addLive(candidates);
    final custom =
        options.mode == ThreadRipperCdnMode.custom &&
        options.customHosts.isNotEmpty;
    return addVod(
      candidates,
      fallbackUrls: custom
          ? candidates
          : [
              for (final value in [url, ...alternatives])
                if (Uri.tryParse(value) case final uri?
                    when ThreadRipperCdn.isMedia(uri))
                  uri,
            ],
    );
  }

  /// Preserve legacy multi-part EDL duration markers and each signed media URL.
  String wrapSource(String source, {Iterable<String> alternatives = const []}) {
    if (!source.startsWith('edl://')) {
      return wrapMedia(source, alternatives: alternatives);
    }
    final result = StringBuffer();
    int offset = 0;
    while (offset < source.length) {
      final marker = source.indexOf('%', offset);
      if (marker < 0) break;
      final lengthEnd = source.indexOf('%', marker + 1);
      if (lengthEnd < 0) return source;
      final length = int.tryParse(source.substring(marker + 1, lengthEnd));
      if (length == null ||
          length < 0 ||
          lengthEnd + 1 + length > source.length) {
        return source;
      }
      final end = lengthEnd + 1 + length;
      final original = source.substring(lengthEnd + 1, end);
      final uri = Uri.tryParse(original);
      final matching = alternatives.where(
        (value) => Uri.tryParse(value)?.path == uri?.path,
      );
      final wrapped = wrapMedia(original, alternatives: matching);
      result
        ..write(source.substring(offset, marker))
        ..write('%${wrapped.length}%$wrapped');
      offset = end;
    }
    result.write(source.substring(offset));
    return result.toString();
  }

  _Transfer _newTransfer() {
    final client = (clientFactory?.call() ?? HttpClient())
      ..autoUncompress = false
      ..connectionTimeout = firstByteTimeout
      ..maxConnectionsPerHost = 32;
    if (upstreamProxy case final proxy?) client.findProxy = (_) => proxy;
    final transfer = _Transfer(client);
    _transfers.add(transfer);
    return transfer;
  }

  void _endTransfer(_Transfer transfer) {
    transfer.cancel();
    _transfers.remove(transfer);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final asset = _assets[request.uri.path];
    if (_closed || asset == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }
    // An Origin header identifies a browser request, not our native player.
    if (request.headers.value('origin') != null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    final transfer = _newTransfer();
    unawaited(
      response.done.then(
        (_) => transfer.cancel(),
        onError: (Object _) => transfer.cancel(),
      ),
    );
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (asset is _VodAsset) {
        await _serveVod(request, asset, transfer);
      } else if (asset is _LiveAsset) {
        await _serveLive(request, asset, transfer);
      }
      await response.close();
    } catch (_) {
      // A failed batch must never be sent as media. Truncate the response so mpv
      // can reopen it at its current position; subsequent requests use fallback.
      if (!transfer.cancelled && !_closed) _status = '下载失败，重试原始线路';
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        try {
          await response.close();
        } catch (_) {}
      }
    } finally {
      _endTransfer(transfer);
    }
  }

  Future<_Upstream> _open(
    _Transfer transfer,
    Uri uri, {
    String method = 'GET',
    String? range,
  }) async {
    transfer.check();
    final request = await transfer.client.openUrl(method, uri);
    transfer.check();
    transfer.requests.add(request);
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.userAgentHeader, userAgent)
      ..headers.set(HttpHeaders.refererHeader, referer)
      ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    try {
      final response = await request.close().timeout(
        firstByteTimeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('First byte timeout');
        },
      );
      transfer.check();
      return _Upstream(request, response);
    } catch (_) {
      request.abort();
      transfer.requests.remove(request);
      rethrow;
    }
  }

  Future<Uint8List> _read(
    _Upstream upstream,
    _Transfer transfer,
    int maximum, {
    int? expected,
  }) async {
    final bytes = BytesBuilder(copy: false);
    final timer = Timer(attemptTimeout, () => upstream.request.abort());
    try {
      await for (final chunk in upstream.response.timeout(stallTimeout)) {
        transfer.check();
        if (bytes.length + chunk.length > maximum) {
          throw const FormatException('Response exceeds range');
        }
        bytes.add(chunk);
      }
      if (expected != null && bytes.length != expected) {
        throw const FormatException('Truncated range');
      }
      return bytes.takeBytes();
    } finally {
      timer.cancel();
      upstream.request.abort();
      transfer.requests.remove(upstream.request);
    }
  }

  List<Uri> _ordered(List<Uri> candidates) {
    if (candidates.isEmpty) return const [];
    final now = _clock.elapsedMilliseconds;
    final available = candidates
        .where((uri) => (_health[uri.host]?.blockedUntil ?? 0) <= now)
        .toList();
    final pool = available.isEmpty ? candidates.toList() : available;
    final offset = _rotation++ % pool.length;
    final rotated = [...pool.skip(offset), ...pool.take(offset)]
      ..sort(
        (a, b) => (_health[b.host]?.speed ?? 0).compareTo(
          _health[a.host]?.speed ?? 0,
        ),
      );
    return rotated;
  }

  void _success(Uri uri, int bytes, int elapsed) {
    _lastHost = uri.host;
    _bytes += bytes;
    final health = _health.putIfAbsent(uri.host, _RouteHealth.new)
      ..failures = 0
      ..blockedUntil = 0;
    if (bytes >= 32 * 1024 && elapsed > 0) {
      final speed = bytes * 1000 / elapsed;
      health.speed = health.speed == 0 ? speed : health.speed * .6 + speed * .4;
    }
  }

  void _failure(Uri uri, {int? status}) {
    final health = _health.putIfAbsent(uri.host, _RouteHealth.new);
    health.failures++;
    health.blockedUntil =
        _clock.elapsedMilliseconds +
        math.min(30000, 1500 * (1 << math.min(health.failures, 4)));
    if (options.automatic && (status == 429 || status == 412)) {
      _concurrency.throttle(_clock.elapsedMilliseconds);
    }
  }

  List<Uri> _startupRoutes(_VodAsset asset, {Uri? preferred}) {
    final routes = _ordered(asset.candidates);
    if (routes.isEmpty) return routes;
    final primary = routes.contains(preferred) ? preferred! : routes.first;
    final original = asset.fallbackUrls
        .where((uri) => uri != primary && routes.contains(uri))
        .firstOrNull;
    return [
      primary,
      ?original,
      ...routes.where((uri) => uri != primary && uri != original),
    ].take(4).toList();
  }

  /// Opening metadata and the first media bytes must not wait for a slow node's
  /// full timeout. Race a backup after 200 ms; all attempts share the same pool.
  Future<T> _raceStartup<T>(
    List<Uri> routes,
    _Transfer owner,
    Future<T> Function(Uri, _Transfer) fetch,
  ) async {
    owner.check();
    if (routes.isEmpty) throw const HttpException('No available media route');
    final winner = Completer<T>();
    final attempts = <_Transfer>[];
    int next = 0;
    int pending = 0;

    void launch() {
      if (_closed ||
          owner.cancelled ||
          winner.isCompleted ||
          next >= routes.length) {
        return;
      }
      final uri = routes[next++];
      final attempt = _newTransfer();
      attempts.add(attempt);
      pending++;
      unawaited(
        _pool
            .run(attempt, () => fetch(uri, attempt))
            .then<void>(
              (value) {
                pending--;
                if (!winner.isCompleted) winner.complete(value);
              },
              onError: (Object error, StackTrace stack) {
                pending--;
                if (_closed || owner.cancelled || winner.isCompleted) return;
                _retries++;
                _failure(uri);
                launch();
                if (pending == 0 && next >= routes.length) {
                  winner.completeError(error, stack);
                }
              },
            )
            .whenComplete(() => _endTransfer(attempt)),
      );
    }

    launch();
    final hedge = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => launch(),
    );
    try {
      return await Future.any([
        winner.future,
        owner.done.future.then<T>(
          (_) => throw StateError('Transfer cancelled'),
        ),
      ]);
    } finally {
      hedge.cancel();
      for (final attempt in attempts) {
        attempt.cancel();
      }
    }
  }

  Future<_MediaInfo?> _probe(_VodAsset asset, _Transfer transfer) async {
    try {
      return await _raceStartup(
        _startupRoutes(asset),
        transfer,
        (uri, attempt) async {
          final upstream = await _open(attempt, uri, range: 'bytes=0-0');
          try {
            final response = upstream.response;
            final range = MediaContentRange.parse(
              response.headers.value(HttpHeaders.contentRangeHeader),
            );
            if (response.statusCode != HttpStatus.partialContent ||
                range == null ||
                range.start != 0 ||
                range.end != 0) {
              _failure(uri, status: response.statusCode);
              throw const FormatException('Invalid metadata range');
            }
            await _read(upstream, attempt, 1, expected: 1);
            return _MediaInfo(
              range.total,
              response.headers.value(HttpHeaders.contentTypeHeader) ??
                  'application/octet-stream',
              uri,
            );
          } finally {
            upstream.request.abort();
            attempt.requests.remove(upstream.request);
          }
        },
      );
    } catch (_) {
      if (transfer.cancelled || _closed) rethrow;
      return null;
    }
  }

  Future<Uint8List> _chunk(
    _VodAsset asset,
    MediaByteRange range,
    int total,
    _Transfer transfer, {
    Uri? startupRoute,
  }) async {
    Future<Uint8List> fetch(Uri uri, _Transfer attempt) async {
      final watch = Stopwatch()..start();
      final upstream = await _open(attempt, uri, range: range.header);
      try {
        final response = upstream.response;
        final actual = MediaContentRange.parse(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (response.statusCode != HttpStatus.partialContent ||
            actual == null ||
            actual.start != range.start ||
            actual.end != range.end ||
            actual.total != total ||
            (response.contentLength >= 0 &&
                response.contentLength != range.length)) {
          _failure(uri, status: response.statusCode);
          throw const FormatException('Invalid content range');
        }
        final bytes = await _read(
          upstream,
          attempt,
          range.length,
          expected: range.length,
        );
        _success(uri, bytes.length, watch.elapsedMilliseconds);
        return bytes;
      } finally {
        upstream.request.abort();
        attempt.requests.remove(upstream.request);
      }
    }

    if (startupRoute != null) {
      return _raceStartup(
        _startupRoutes(asset, preferred: startupRoute),
        transfer,
        fetch,
      );
    }
    Object? failure;
    for (final uri in _ordered(asset.candidates).take(4)) {
      transfer.check();
      try {
        return await _pool.run(transfer, () => fetch(uri, transfer));
      } catch (error) {
        if (transfer.cancelled || _closed) rethrow;
        failure = error;
        _retries++;
        _failure(uri);
      }
    }
    throw failure ?? const HttpException('No available media route');
  }

  Future<void> _serveVod(
    HttpRequest request,
    _VodAsset asset,
    _Transfer transfer,
  ) async {
    if (asset.degraded) {
      return _passthrough(request, asset.fallbackUrls, transfer);
    }
    final info = await (asset.info ??= _loadInfo(asset));
    transfer.check();
    if (info == null) {
      asset
        ..info = null
        ..degraded = true;
      _fallbacks++;
      _status = '原始线路（节点不支持分段下载）';
      return _passthrough(request, asset.fallbackUrls, transfer);
    }
    final header = request.headers.value(HttpHeaders.rangeHeader);
    final range = MediaByteRange.fromHeader(header, info.total);
    // Send short demuxer reads immediately instead of retaining them in Dart's
    // HTTP output buffer until another range finishes.
    final response = request.response..bufferOutput = false;
    if (range == null) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */${info.total}');
      return;
    }
    response
      ..statusCode = header == null ? HttpStatus.ok : HttpStatus.partialContent
      ..contentLength = range.length
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentTypeHeader, info.contentType);
    if (header != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/${info.total}',
      );
    }
    if (request.method == 'HEAD') return;
    _status = '并发分段下载';
    int cursor = range.start;
    bool committed = false;
    try {
      // Give the demuxer a small validated prefix before filling the parallel
      // window. Waiting for 16–32 full chunks here delays every source open.
      final firstEnd = math.min<int>(
        cursor + math.min<int>(chunkBytes, 32 * 1024) - 1,
        range.end,
      );
      final first = await _chunk(
        asset,
        MediaByteRange(cursor, firstEnd),
        info.total,
        transfer,
        startupRoute: info.route,
      );
      transfer.check();
      committed = true;
      response.add(first);
      await response.flush();
      cursor = firstEnd + 1;
      while (cursor <= range.end) {
        transfer.check();
        final batch = <MediaByteRange>[];
        for (var index = 0; index < _limit && cursor <= range.end; index++) {
          final end = math.min(cursor + chunkBytes - 1, range.end);
          batch.add(MediaByteRange(cursor, end));
          cursor = end + 1;
        }
        final watch = Stopwatch()..start();
        // At most 8 MiB per consumer in flight. Observe every future immediately
        // so a later failure is handled even while an earlier chunk is pending.
        final chunks = batch.map((piece) {
          final future = _chunk(asset, piece, info.total, transfer);
          unawaited(future.then<void>((_) {}, onError: (Object _) {}));
          return future;
        }).toList();
        int bytes = 0;
        for (final chunk in chunks) {
          final data = await chunk;
          transfer.check();
          response.add(data);
          await response.flush();
          bytes += data.length;
        }
        _tune(bytes, watch.elapsedMilliseconds);
      }
    } catch (_) {
      if (!transfer.cancelled && !_closed) {
        asset.degraded = true;
        _fallbacks++;
        _status = '已回退原始播放路线';
        if (!committed) {
          response.contentLength = -1;
          for (final name in [
            HttpHeaders.contentRangeHeader,
            HttpHeaders.contentLengthHeader,
            HttpHeaders.contentTypeHeader,
            HttpHeaders.acceptRangesHeader,
          ]) {
            response.headers.removeAll(name);
          }
          return _passthrough(request, asset.fallbackUrls, transfer);
        }
        onFallback?.call();
      }
      rethrow;
    }
  }

  Future<_MediaInfo?> _loadInfo(_VodAsset asset) async {
    // Metadata is shared by concurrent seeks. Closing one downstream request
    // must not poison the cached probe for the next player request.
    final transfer = _newTransfer();
    try {
      return await _probe(asset, transfer);
    } catch (_) {
      asset.info = null;
      rethrow;
    } finally {
      _endTransfer(transfer);
    }
  }

  Future<void> _passthrough(
    HttpRequest request,
    List<Uri> candidates,
    _Transfer transfer,
  ) async {
    if (candidates.isEmpty) throw const HttpException('No original route');
    bool committed = false;
    for (final uri in candidates) {
      try {
        await _pool.run(transfer, () async {
          final upstream = await _open(
            transfer,
            uri,
            method: request.method,
            range: request.headers.value(HttpHeaders.rangeHeader),
          );
          try {
            final source = upstream.response;
            if (source.statusCode >= 300 && uri != candidates.last) {
              throw const HttpException('Original route unavailable');
            }
            final response = request.response..statusCode = source.statusCode;
            for (final name in [
              HttpHeaders.contentTypeHeader,
              HttpHeaders.contentRangeHeader,
              HttpHeaders.acceptRangesHeader,
              HttpHeaders.contentLengthHeader,
            ]) {
              if (source.headers.value(name) case final value?) {
                response.headers.set(name, value);
              }
            }
            _lastHost = uri.host;
            if (request.method != 'HEAD') {
              await for (final chunk in source.timeout(stallTimeout)) {
                transfer.check();
                committed = true;
                response.add(chunk);
                _bytes += chunk.length;
                await response.flush();
              }
            }
          } finally {
            upstream.request.abort();
            transfer.requests.remove(upstream.request);
          }
        });
        return;
      } catch (_) {
        if (committed ||
            transfer.cancelled ||
            _closed ||
            uri == candidates.last) {
          rethrow;
        }
      }
    }
  }

  void _tune(int bytes, int elapsed) {
    if (_concurrency.observe(bytes, elapsed, _clock.elapsedMilliseconds)) {
      _pool.pump();
    }
  }

  void _publish() {
    if (_closed) return;
    final now = _clock.elapsedMilliseconds;
    final elapsed = math.max(1, now - _sampleAt);
    stats.value = ThreadRipperStats(
      activeThreads: _pool.active,
      threadLimit: _limit,
      bytesPerSecond: (_bytes - _sampleBytes) * 1000 ~/ elapsed,
      downloadedBytes: _bytes,
      retries: _retries,
      fallbacks: _fallbacks,
      lastHost: _lastHost,
      status: _status,
    );
    _sampleBytes = _bytes;
    _sampleAt = now;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _statsTimer?.cancel();
    for (final transfer in _transfers) {
      transfer.cancel();
    }
    _transfers.clear();
    _pool.pump();
    final server = _server;
    _server = null;
    _assets.clear();
    _health.clear();
    await server?.close(force: true);
    stats.dispose();
  }
}

sealed class _Asset {
  _Asset(this.candidates);
  final List<Uri> candidates;
}

class _VodAsset extends _Asset {
  _VodAsset(super.candidates, this.fallbackUrls);
  final List<Uri> fallbackUrls;
  Future<_MediaInfo?>? info;
  bool degraded = false;
}

class _MediaInfo {
  const _MediaInfo(this.total, this.contentType, this.route);
  final int total;
  final String contentType;
  final Uri route;
}

class _RouteHealth {
  int failures = 0;
  int blockedUntil = 0;
  double speed = 0;
}

class _Upstream {
  const _Upstream(this.request, this.response);
  final HttpClientRequest request;
  final HttpClientResponse response;
}

class _Transfer {
  _Transfer(this.client);
  final HttpClient client;
  final requests = <HttpClientRequest>{};
  final done = Completer<void>();
  bool cancelled = false;
  void check() {
    if (cancelled) throw StateError('Transfer cancelled');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final request in requests) {
      request.abort();
    }
    requests.clear();
    client.close(force: true);
    done.complete();
  }
}

class _TransferPool {
  _TransferPool(this.limit);
  final int Function() limit;
  final _waiting = Queue<(_Transfer, Completer<void>)>();
  int active = 0;

  Future<T> run<T>(_Transfer transfer, Future<T> Function() action) async {
    transfer.check();
    final ready = Completer<void>();
    _waiting.add((transfer, ready));
    pump();
    await Future.any([ready.future, transfer.done.future]);
    if (transfer.cancelled && !ready.isCompleted) {
      _waiting.removeWhere((entry) => entry.$2 == ready);
      transfer.check();
    }
    try {
      transfer.check();
      return await action();
    } finally {
      active--;
      pump();
    }
  }

  void pump() {
    while (_waiting.isNotEmpty && active < limit()) {
      final (transfer, ready) = _waiting.removeFirst();
      if (transfer.cancelled) continue;
      active++;
      ready.complete();
    }
  }
}
