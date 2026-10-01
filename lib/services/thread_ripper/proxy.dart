import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/routes.dart';
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
    this.onActiveRequestsChanged,
    ThreadRipperConcurrency? concurrencyController,
    this.chunkBytes = 256 * 1024,
    this.firstByteTimeout = const Duration(milliseconds: 5500),
    this.stallTimeout = const Duration(seconds: 4),
    this.attemptTimeout = const Duration(seconds: 15),
  }) : assert(chunkBytes > 0) {
    _concurrency = options.automatic && concurrencyController != null
        ? concurrencyController
        : ThreadRipperConcurrency(concurrency: options.concurrency);
    _pool = _TransferPool(() => _limit, _demand);
    _tunerListener = _pool.pump;
  }

  final ThreadRipperOptions options;
  final String userAgent;
  final String referer;
  final String? upstreamProxy;
  final VoidCallback? onFallback;

  /// Allows deterministic transport tests without contacting Bilibili.
  final HttpClient Function()? clientFactory;
  final ValueChanged<int>? onActiveRequestsChanged;
  final int chunkBytes;
  final Duration firstByteTimeout;
  final Duration stallTimeout;
  final Duration attemptTimeout;
  final stats = ValueNotifier(const ThreadRipperStats());
  final _assets = <String, _Asset>{};
  final _transfers = <_Transfer>{};
  final _health = <String, _RouteHealth>{};
  final _clock = Stopwatch()..start();
  final _assignments = ThreadRipperAssignments();
  late final _TransferPool _pool;
  late final VoidCallback _tunerListener;
  late final HttpClient _client = _createClient();
  HttpServer? _server;
  Timer? _statsTimer;
  bool _closed = false;
  late final ThreadRipperConcurrency _concurrency;
  ThreadRipperConcurrency get concurrencyController => _concurrency;
  bool get _ownsTuner => identical(_concurrency.onChanged, _tunerListener);
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
    _concurrency.newSession();
    _concurrency.onChanged = _tunerListener;
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
  String addVod(
    List<Uri> candidates, {
    List<Uri>? fallbackUrls,
    bool isAudio = false,
  }) => _register(
    _VodAsset(
      candidates,
      fallbackUrls ?? candidates,
      isAudio,
      options.mode != ThreadRipperCdnMode.mainland,
    ),
    '.m4s',
  );

  String addLive(List<Uri> candidates) => _addLive(candidates);

  String wrapMedia(
    String url, {
    Iterable<String> alternatives = const [],
    bool live = false,
    bool rewriteCdn = true,
    bool isAudio = false,
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
      isAudio: isAudio,
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

  HttpClient _createClient() {
    final client = (clientFactory?.call() ?? HttpClient())
      ..autoUncompress = false
      ..connectionTimeout = firstByteTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 32;
    if (upstreamProxy case final proxy?) client.findProxy = (_) => proxy;
    return client;
  }

  _Transfer _newTransfer([_Transfer? parent]) {
    final transfer = _Transfer(_client, parent);
    _transfers.add(transfer);
    return transfer;
  }

  void _endTransfer(_Transfer transfer) {
    transfer.cancel();
    transfer.parent?.children.remove(transfer);
    _transfers.remove(transfer);
  }

  Future<void> _serve(HttpRequest request) async {
    final asset = _assets[request.uri.path];
    final originalResponse = request.response;
    if (_closed || asset == null) {
      originalResponse.statusCode = HttpStatus.notFound;
      await originalResponse.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      originalResponse
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await originalResponse.close();
      return;
    }
    if (request.headers.value('origin') != null) {
      originalResponse.statusCode = HttpStatus.forbidden;
      await originalResponse.close();
      return;
    }

    final transfer = _newTransfer();
    _Downstream? response;
    try {
      // HttpResponse.done does not reliably notice a seek while a large response
      // is being written. Own the socket so a FIN/RST cancels upstream work now.
      final socket = await originalResponse.detachSocket(writeHeaders: false);
      response = _Downstream(socket, transfer, head: request.method == 'HEAD');
      if (asset is _VodAsset && request.method == 'GET') {
        // mpv can open the new seek before closing the previous connection.
        asset.request?.cancel();
        asset.request = transfer;
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (asset is _VodAsset) {
        await _serveVod(request, response, asset, transfer);
      } else if (asset is _LiveAsset) {
        await _serveLive(request, response, asset, transfer);
      }
      await response.close();
    } catch (_) {
      if (!transfer.cancelled && !_closed) {
        _status = '下载失败，重试原始线路';
        if (response != null && !response.committed) {
          response
            ..statusCode = HttpStatus.badGateway
            ..contentLength = 0;
          response.headers.clear();
          try {
            await response.close();
          } catch (_) {}
        }
      }
      response?.destroy();
    } finally {
      if (asset is _VodAsset && identical(asset.request, transfer)) {
        asset.request = null;
      }
      response?.destroy();
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
    final watch = Stopwatch()..start();
    HttpClientRequest? request;
    bool finished = false;
    // A timeout must also abort an openUrl that resolves late (e.g. slow DNS).
    final opening = transfer.client.openUrl(method, uri).then((value) {
      if (finished || transfer.cancelled) value.abort();
      return value;
    });
    try {
      request = await transfer.race(opening).timeout(firstByteTimeout);
      transfer.check();
      transfer.requests.add(request);
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.userAgentHeader, userAgent)
        ..headers.set(HttpHeaders.refererHeader, referer)
        ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      // Connecting and response headers share one deadline, rather than each
      // consuming a separate 5.5 seconds.
      final remaining = firstByteTimeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('First byte timeout');
      }
      final response = await transfer.race(request.close()).timeout(remaining);
      transfer.check();
      return _Upstream(request, response, watch);
    } catch (_) {
      request?.abort();
      transfer.requests.remove(request);
      rethrow;
    } finally {
      finished = true;
    }
  }

  void _release(_Upstream upstream, _Transfer transfer) {
    // A fully consumed, validated response may reuse its HTTP/TLS connection.
    if (!upstream.completed) upstream.request.abort();
    transfer.requests.remove(upstream.request);
  }

  Future<Uint8List> _read(
    _Upstream upstream,
    _Transfer transfer,
    int maximum, {
    int? expected,
    _Receiving? receiving,
  }) async {
    final bytes = BytesBuilder(copy: false);
    final remaining = attemptTimeout - upstream.watch.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('Attempt timeout');
    final timer = Timer(remaining, () => upstream.request.abort());
    try {
      await transfer.race(() async {
        await for (final chunk in upstream.response.timeout(stallTimeout)) {
          transfer.check();
          if (bytes.length + chunk.length > maximum) {
            receiving?.chunks.clear();
            throw const FormatException('Response exceeds range');
          }
          bytes.add(chunk);
          receiving?.chunks.add(chunk);
          if (_ownsTuner) _concurrency.activity();
        }
      }());
      if (expected != null && bytes.length != expected) {
        throw const FormatException('Truncated range');
      }
      upstream.completed = true;
      return bytes.takeBytes();
    } finally {
      timer.cancel();
    }
  }

  // Live routing keeps its own lightweight history. VOD uses per-track routing
  // with weighted assignments, signature-aware failures, and expiring samples.
  List<Uri> _ordered(List<Uri> candidates) {
    if (candidates.isEmpty) return const [];
    final now = _clock.elapsedMilliseconds;
    final available = candidates
        .where((uri) => (_health[uri.toString()]?.blockedUntil ?? 0) <= now)
        .toList();
    final pool = available.isEmpty ? candidates.toList() : available;
    final offset = _rotation++ % pool.length;
    final rotated = [...pool.skip(offset), ...pool.take(offset)];
    final positions = {for (var i = 0; i < rotated.length; i++) rotated[i]: i};
    double speed(Uri uri) {
      final h = _health['${uri.authority}${uri.path}'];
      return h != null && now - h.measuredAt < 90000 ? h.speed : 0;
    }

    rotated.sort((a, b) {
      final bySpeed = speed(b).compareTo(speed(a));
      return bySpeed != 0 ? bySpeed : positions[a]!.compareTo(positions[b]!);
    });
    return rotated;
  }

  void _success(Uri uri, int bytes, int elapsed) {
    _lastHost = uri.host;
    _health[uri.toString()] = _RouteHealth()
      ..touchedAt = _clock.elapsedMilliseconds;
    if (bytes >= 48 * 1024 && elapsed > 0) {
      final health = _health.putIfAbsent(
        '${uri.authority}${uri.path}',
        _RouteHealth.new,
      );
      final speed = bytes * 1000 / elapsed;
      health.speed = health.speed == 0
          ? speed
          : health.speed * .65 + speed * .35;
      health.measuredAt = _clock.elapsedMilliseconds;
      health.touchedAt = health.measuredAt;
    }
  }

  void _failure(Uri uri, {int? status}) {
    final health = _health.putIfAbsent(uri.toString(), _RouteHealth.new);
    health.failures++;
    health.touchedAt = _clock.elapsedMilliseconds;
    health.blockedUntil =
        _clock.elapsedMilliseconds +
        math.min(30000, 1500 * (1 << math.min(health.failures, 4)));
    if (_ownsTuner && (status == 429 || status == 412)) {
      _concurrency.pushback();
    }
  }

  void _delivered(int bytes) {
    _bytes += bytes;
    if (_ownsTuner) _concurrency.delivered(bytes);
  }

  void _demand(int active, int limit, int queued) {
    onActiveRequestsChanged?.call(active);
    if (_ownsTuner) _concurrency.demand(active, limit, queued);
  }

  List<Uri> _startupRoutes(_VodAsset asset, {Uri? preferred}) {
    final routes = asset.routes.rescueCandidates();
    if (routes.isEmpty) routes.addAll(asset.routes.ordered());
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

  /// All attempts, including hedges, share the strict priority connection pool.
  /// A reserved slot lets a backup run even when normal downloads are stalled.
  Future<T> _raceRoutes<T>(
    List<Uri> routes,
    _Transfer owner,
    Future<T> Function(Uri, _Transfer, bool) fetch, {
    int priority = 220,
    Duration hedgeDelay = const Duration(milliseconds: 120),
    int parallel = 3,
    bool Function(Uri)? eligible,
  }) async {
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
          next >= routes.length ||
          pending >= parallel) {
        return;
      }
      final rescue = next > 0;
      final uri = routes[next++];
      final attempt = _newTransfer(owner);
      attempts.add(attempt);
      pending++;
      unawaited(
        _pool
            .run(
              attempt,
              () {
                if (eligible != null && !eligible(uri)) {
                  throw const HttpException('Route no longer available');
                }
                return fetch(uri, attempt, rescue);
              },
              priority: priority + (rescue ? 20 : 0),
              rescue: rescue,
            )
            .then<void>(
              (value) {
                pending--;
                if (!winner.isCompleted) winner.complete(value);
              },
              onError: (Object error, StackTrace stack) {
                pending--;
                if (_closed || owner.cancelled || winner.isCompleted) return;
                _retries++;
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
    final hedge = Timer.periodic(hedgeDelay, (_) => launch());
    try {
      return await owner.race(winner.future);
    } finally {
      hedge.cancel();
      for (final attempt in attempts) {
        attempt.cancel();
      }
    }
  }

  Future<_MediaInfo?> _probe(
    _VodAsset asset,
    _Transfer transfer, {
    required bool prefix,
  }) async {
    try {
      final end = prefix ? math.min(chunkBytes, 64 * 1024) - 1 : 0;
      final info = await _raceRoutes(
        _startupRoutes(asset),
        transfer,
        (uri, attempt, rescue) async {
          _Upstream? upstream;
          int status = 0;
          try {
            upstream = await _open(attempt, uri, range: 'bytes=0-$end');
            final response = upstream.response;
            status = response.statusCode;
            final actual = MediaContentRange.parse(
              response.headers.value(HttpHeaders.contentRangeHeader),
            );
            if (status != HttpStatus.partialContent ||
                actual == null ||
                actual.start != 0 ||
                actual.end != math.min(end, actual.total - 1) ||
                (response.contentLength >= 0 &&
                    response.contentLength != actual.length)) {
              throw const FormatException('Invalid metadata range');
            }
            final bytes = await _read(
              upstream,
              attempt,
              actual.length,
              expected: actual.length,
            );
            asset.routes.success(uri, bytes.length, upstream.watch.elapsed);
            _lastHost = uri.host;
            return _MediaInfo(
              actual.total,
              response.headers.value(HttpHeaders.contentTypeHeader) ??
                  'application/octet-stream',
              uri,
              prefix ? bytes : null,
            );
          } catch (_) {
            if (!attempt.cancelled) {
              asset.routes.failure(uri, status: status);
              if (_ownsTuner && (status == 429 || status == 412)) {
                _concurrency.pushback();
              }
            }
            rethrow;
          } finally {
            if (upstream != null) _release(upstream, attempt);
          }
        },
      );
      _delivered(info.prefix?.length ?? 1);
      return info;
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
    Uri? primary,
    int priority = 55,
    bool hurry = false,
  }) async {
    final resume = _Resume(range.length);
    _Receiving? leader;

    Future<Uint8List> fetch(Uri uri, _Transfer attempt, bool rescue) async {
      final receiving = _Receiving();
      // Snapshot only after a slot is granted: the primary can make progress
      // while its backup waits. Retain only a validated contiguous prefix.
      resume.keep(leader?.snapshot());
      if (resume.prefix case final prefix?
          when prefix.length >= 32 * 1024 && prefix.length < range.length) {
        receiving.base = prefix;
      }
      if (!rescue) leader = receiving;
      final start = range.start + (receiving.base?.length ?? 0);
      _Upstream? upstream;
      int status = 0;
      try {
        upstream = await _open(
          attempt,
          uri,
          range: 'bytes=$start-${range.end}',
        );
        final response = upstream.response;
        status = response.statusCode;
        final actual = MediaContentRange.parse(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        final expected = range.end - start + 1;
        if (status != HttpStatus.partialContent ||
            actual == null ||
            actual.start != start ||
            actual.end != range.end ||
            actual.total != total ||
            (response.contentLength >= 0 &&
                response.contentLength != expected)) {
          throw const FormatException('Invalid content range');
        }
        final tail = await _read(
          upstream,
          attempt,
          expected,
          expected: expected,
          receiving: receiving,
        );
        asset.routes.success(uri, tail.length, upstream.watch.elapsed);
        _lastHost = uri.host;
        final bytes = BytesBuilder(copy: false);
        if (receiving.base case final prefix?) bytes.add(prefix);
        bytes.add(tail);
        return bytes.takeBytes();
      } catch (error) {
        resume.keep(receiving.snapshot());
        if (!attempt.cancelled) {
          asset.routes.failure(
            uri,
            status: status,
            received: receiving.received,
          );
          if (_ownsTuner) {
            if (status == 429 || status == 412) {
              _concurrency.pushback();
            } else if (error is TimeoutException && receiving.received == 0) {
              _concurrency.slow();
            }
          }
        }
        rethrow;
      } finally {
        if (upstream != null) _release(upstream, attempt);
      }
    }

    Object? failure;
    for (var round = 0; round < 3; round++) {
      transfer.check();
      if (round > 0) {
        // Retry a useful interrupted prefix; do not repeatedly probe a node
        // with broken Range support before allowing our original-route fallback.
        if ((resume.prefix?.length ?? 0) < 32 * 1024) break;
        await transfer.race(
          Future<void>.delayed(Duration(milliseconds: 150 * round)),
        );
      }
      final routes = startupRoute != null
          ? _startupRoutes(asset, preferred: startupRoute)
          : asset.routes
                .pieceCandidates(
                  primary == null ? const [] : [primary],
                  round,
                  round,
                )
                .take(8)
                .toList();
      final speed = primary == null ? 0.0 : asset.routes.speed(primary);
      final hedgeMs = hurry || startupRoute != null
          ? 120
          : speed <= 0
          ? 350
          : (range.length * 1250 / speed).round().clamp(250, 900);
      try {
        final bytes = await _raceRoutes(
          routes,
          transfer,
          fetch,
          priority: startupRoute != null ? 220 : priority,
          hedgeDelay: Duration(milliseconds: hedgeMs),
          parallel: startupRoute != null ? 3 : 2,
          eligible: (uri) =>
              asset.routes.available(uri) ||
              (!routes.any(asset.routes.available) &&
                  asset.routes.bans.allows(uri)),
        );
        _delivered(bytes.length);
        return bytes;
      } catch (error) {
        if (transfer.cancelled || _closed) rethrow;
        failure = error;
      }
    }
    throw failure ?? const HttpException('No available media route');
  }

  int _budget(_VodAsset asset) {
    if (asset.isAudio) return math.min(2, _pool.normalLimit);
    final hasAudio = _assets.values.any(
      (other) => other is _VodAsset && other.isAudio,
    );
    return math.max(1, _pool.normalLimit - (hasAudio ? 2 : 1));
  }

  int _pieceSize(_VodAsset asset, int remaining, int budget) {
    // Explicit test sizes remain deterministic.
    if (chunkBytes != 256 * 1024) return math.min(chunkBytes, 1024 * 1024);
    final speeds = asset.candidates
        .where(asset.routes.available)
        .map(asset.routes.speed)
        .where((speed) => speed > 0)
        .toList();
    final speed = speeds.isEmpty
        ? 0.0
        : speeds.reduce((a, b) => a + b) / speeds.length;
    final floor = asset.isAudio ? 256 * 1024 : 64 * 1024;
    final target = speed == 0 ? chunkBytes : (speed * .6).round();
    final spread = (math.min(remaining, 2 * 1024 * 1024) / budget).ceil();
    // Keep a window within one round of its connection budget. Tiny pieces on
    // high-RTT links otherwise turn a small window into dozens of round trips.
    return math.max(floor, math.min(1024 * 1024, math.max(target, spread)));
  }

  Future<void> _serveVod(
    HttpRequest request,
    _Downstream response,
    _VodAsset asset,
    _Transfer transfer,
  ) async {
    if (asset.degraded) {
      return _passthrough(request, response, asset.fallbackUrls, transfer);
    }
    final header = request.headers.value(HttpHeaders.rangeHeader);
    final initial =
        request.method == 'GET' &&
        (header == null ||
            RegExp(
              r'^bytes=0-\d*$',
              caseSensitive: false,
            ).hasMatch(header.trim()));
    final info = await transfer.race(
      asset.info ??= _loadInfo(asset, prefix: initial),
    );
    transfer.check();
    if (info == null) {
      asset
        ..info = null
        ..degraded = true;
      _fallbacks++;
      _status = '原始线路（节点不支持分段下载）';
      return _passthrough(request, response, asset.fallbackUrls, transfer);
    }
    final range = MediaByteRange.fromHeader(header, info.total);
    if (range == null) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..contentLength = 0
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
    try {
      // Initial GET obtains metadata and the demuxer prefix in one request.
      // HEAD and tail/suffix seeks retain the minimal single-byte probe.
      final cached = cursor == 0 ? info.prefix : null;
      final first = cached != null
          ? Uint8List.sublistView(
              cached,
              0,
              math.min(cached.length, range.length),
            )
          : await _chunk(
              asset,
              MediaByteRange(
                cursor,
                math.min<int>(
                  cursor + math.min<int>(chunkBytes, 64 * 1024) - 1,
                  range.end,
                ),
              ),
              info.total,
              transfer,
              startupRoute: info.route,
            );
      transfer.check();
      response.add(first);
      await response.flush();
      cursor += first.length;

      final pending = Queue<Future<_ChunkResult>>();
      final assignments = Queue<Uri>();
      int pieceIndex = 0;
      int queuedBytes = 0;

      void fill() {
        transfer.check();
        final budget = _budget(asset);
        final size = _pieceSize(asset, range.end - cursor + 1, budget);
        while (cursor <= range.end &&
            pending.length < budget &&
            queuedBytes + math.min(size, range.end - cursor + 1) <=
                2 * 1024 * 1024) {
          if (assignments.isEmpty) {
            assignments.addAll(
              _assignments.assign(
                asset.routes.rangeCandidates(),
                asset.routes,
                math.max(2, budget),
              ),
            );
          }
          final end = math.min(cursor + size - 1, range.end);
          final piece = MediaByteRange(cursor, end);
          final chosen = assignments.isEmpty ? null : assignments.removeFirst();
          final index = pieceIndex++;
          // Convert failures to values immediately, even if a later piece fails
          // while an earlier one is still pending.
          pending.add(
            _chunk(
              asset,
              piece,
              info.total,
              transfer,
              primary: chosen,
              priority: asset.isAudio
                  ? 90
                  : index < 2
                  ? 120
                  : 55,
              hurry: index < 2,
            ).then(
              (bytes) => _ChunkResult(bytes, null, null, piece.length),
              onError: (Object error, StackTrace stack) =>
                  _ChunkResult(null, error, stack, piece.length),
            ),
          );
          queuedBytes += piece.length;
          cursor = end + 1;
        }
      }

      fill();
      while (pending.isNotEmpty) {
        final result = await transfer.race(pending.removeFirst());
        queuedBytes -= result.length;
        if (result.error != null) {
          Error.throwWithStackTrace(result.error!, result.stack!);
        }
        transfer.check();
        response.add(result.bytes!);
        await response.flush();
        // Sliding window: refill now, without waiting for its slowest sibling.
        fill();
      }
    } catch (_) {
      if (!transfer.cancelled && !_closed) {
        asset.degraded = true;
        _fallbacks++;
        _status = '已回退原始播放路线';
        if (!response.committed) {
          response.headers.clear();
          response.contentLength = -1;
          return _passthrough(request, response, asset.fallbackUrls, transfer);
        }
        onFallback?.call();
      }
      rethrow;
    }
  }

  Future<_MediaInfo?> _loadInfo(_VodAsset asset, {required bool prefix}) async {
    // A shared, bounded probe survives an abandoned seek. Its result remains
    // usable by the next request without poisoning metadata with cancellation.
    final transfer = _newTransfer();
    try {
      return await _probe(asset, transfer, prefix: prefix);
    } catch (_) {
      asset.info = null;
      rethrow;
    } finally {
      _endTransfer(transfer);
    }
  }

  Future<void> _passthrough(
    HttpRequest request,
    _Downstream response,
    List<Uri> candidates,
    _Transfer transfer,
  ) async {
    if (candidates.isEmpty) throw const HttpException('No original route');
    for (final uri in candidates) {
      try {
        await _pool.run(
          transfer,
          () async {
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
              response.statusCode = source.statusCode;
              response.headers.clear();
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
              response.contentLength = source.contentLength;
              _lastHost = uri.host;
              await transfer.race(() async {
                await for (final chunk in source.timeout(stallTimeout)) {
                  transfer.check();
                  if (request.method != 'HEAD') {
                    response.add(chunk);
                    _delivered(chunk.length);
                    await response.flush();
                  }
                }
              }());
              upstream.completed = true;
            } finally {
              _release(upstream, transfer);
            }
          },
          priority: 220,
          rescue: true,
        );
        return;
      } catch (_) {
        if (response.committed ||
            transfer.cancelled ||
            _closed ||
            uri == candidates.last) {
          rethrow;
        }
      }
    }
  }

  void _publish() {
    if (_closed) return;
    final now = _clock.elapsedMilliseconds;
    _health.removeWhere((_, health) => now - health.touchedAt > 120000);
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
    if (_ownsTuner) {
      _concurrency.onChanged = null;
      _concurrency.demand(0, _limit, 0);
    }
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    _transfers.clear();
    _pool.pump();
    _client.close(force: true);
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
  _VodAsset(super.candidates, this.fallbackUrls, this.isAudio, bool overseas)
    : routes = ThreadRipperRoutes(candidates, overseas: overseas);
  final List<Uri> fallbackUrls;
  final bool isAudio;
  final ThreadRipperRoutes routes;
  Future<_MediaInfo?>? info;
  _Transfer? request;
  bool degraded = false;
}

class _MediaInfo {
  const _MediaInfo(this.total, this.contentType, this.route, this.prefix);
  final int total;
  final String contentType;
  final Uri route;
  final Uint8List? prefix;
}

class _RouteHealth {
  int failures = 0;
  int blockedUntil = 0;
  int measuredAt = 0;
  int touchedAt = 0;
  double speed = 0;
}

class _Upstream {
  _Upstream(this.request, this.response, this.watch);
  final HttpClientRequest request;
  final HttpClientResponse response;
  final Stopwatch watch;
  bool completed = false;
}

class _Transfer {
  _Transfer(this.client, this.parent) {
    parent?.children.add(this);
    if (parent?.cancelled == true) cancel();
  }
  final HttpClient client;
  final _Transfer? parent;
  final children = <_Transfer>{};
  final requests = <HttpClientRequest>{};
  final done = Completer<void>();
  final _listeners = <VoidCallback>{};
  bool cancelled = false;

  // Remove cancellation listeners after each wait. Long media streams must not
  // accumulate a Future.any listener for every chunk until the whole GET ends.
  Future<T> race<T>(Future<T> operation) async {
    final result = Completer<T>();
    void cancelWait() {
      if (!result.isCompleted) {
        result.completeError(const HttpException('Transfer cancelled'));
      }
    }

    _listeners.add(cancelWait);
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    if (cancelled) cancelWait();
    try {
      return await result.future;
    } finally {
      _listeners.remove(cancelWait);
    }
  }

  void check() {
    if (cancelled) throw const HttpException('Transfer cancelled');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    for (final request in requests.toList()) {
      request.abort();
    }
    requests.clear();
    for (final child in children.toList()) {
      child.cancel();
    }
    done.complete();
  }
}

class _Waiter {
  _Waiter(this.transfer, this.priority, this.rescue, this.sequence);
  final _Transfer transfer;
  final int priority;
  final bool rescue;
  final int sequence;
  final ready = Completer<void>();
  bool granted = false;
}

class _TransferPool {
  _TransferPool(this.limit, this.onDemand);
  final int Function() limit;
  final void Function(int, int, int) onDemand;
  final _waiting = <_Waiter>[];
  int active = 0;
  int _normalActive = 0;
  int _sequence = 0;
  int get normalLimit => math.max(1, limit() - (limit() / 8).ceil());

  Future<T> run<T>(
    _Transfer transfer,
    Future<T> Function() action, {
    int priority = 55,
    bool rescue = false,
  }) async {
    transfer.check();
    final waiter = _Waiter(transfer, priority, rescue, _sequence++);
    _waiting.add(waiter);
    pump();
    try {
      await transfer.race(waiter.ready.future);
      transfer.check();
      return await action();
    } finally {
      _waiting.remove(waiter);
      if (waiter.granted) {
        active--;
        if (!rescue) _normalActive--;
      }
      pump();
    }
  }

  void pump() {
    _waiting.removeWhere((waiter) => waiter.transfer.cancelled);
    _waiting.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
    });
    while (active < limit()) {
      final index = _waiting.indexWhere(
        (waiter) => waiter.rescue || _normalActive < normalLimit,
      );
      if (index < 0) break;
      final waiter = _waiting.removeAt(index)..granted = true;
      active++;
      if (!waiter.rescue) _normalActive++;
      waiter.ready.complete();
    }
    onDemand(active, limit(), _waiting.length);
  }
}

class _Resume {
  _Resume(this.length);
  final int length;
  Uint8List? prefix;
  void keep(Uint8List? bytes) {
    if (bytes != null &&
        bytes.length > (prefix?.length ?? 0) &&
        bytes.length < length) {
      prefix = bytes;
    }
  }
}

class _Receiving {
  Uint8List? base;
  final chunks = <List<int>>[];
  int get received => chunks.fold(0, (sum, chunk) => sum + chunk.length);
  Uint8List snapshot() {
    final bytes = BytesBuilder(copy: false);
    if (base != null) bytes.add(base!);
    for (final chunk in chunks) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

class _ChunkResult {
  const _ChunkResult(this.bytes, this.error, this.stack, this.length);
  final Uint8List? bytes;
  final Object? error;
  final StackTrace? stack;
  final int length;
}

class _LocalHeaders {
  final values = <String, String>{};
  void set(String name, Object value) {
    final text = value.toString();
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(name) ||
        text.contains('\r') ||
        text.contains('\n')) {
      throw const FormatException('Invalid HTTP header');
    }
    values[name.toLowerCase()] = text;
  }

  void removeAll(String name) => values.remove(name.toLowerCase());
  void clear() => values.clear();
}

class _Downstream {
  _Downstream(this.socket, this.transfer, {required this.head}) {
    socket.listen(
      (_) {},
      onDone: transfer.cancel,
      onError: (Object _) => transfer.cancel(),
    );
    unawaited(transfer.done.future.then((_) => socket.destroy()));
  }
  final Socket socket;
  final _Transfer transfer;
  final bool head;
  final headers = _LocalHeaders();
  int statusCode = HttpStatus.ok;
  int contentLength = -1;
  bool committed = false;

  void _commit() {
    if (committed) return;
    transfer.check();
    committed = true;
    if (contentLength >= 0) {
      headers.set(HttpHeaders.contentLengthHeader, contentLength);
    }
    headers
      ..set(HttpHeaders.connectionHeader, 'close')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    final reason = switch (statusCode) {
      200 => 'OK',
      206 => 'Partial Content',
      416 => 'Range Not Satisfiable',
      502 => 'Bad Gateway',
      _ => 'Response',
    };
    final text = StringBuffer('HTTP/1.1 $statusCode $reason\r\n');
    headers.values.forEach((name, value) => text.write('$name: $value\r\n'));
    text.write('\r\n');
    socket.add(ascii.encode(text.toString()));
  }

  void add(List<int> bytes) {
    _commit();
    if (!head) socket.add(bytes);
  }

  Future<void> flush() => transfer.race(socket.flush());

  Future<void> close() async {
    _commit();
    await flush();
    await transfer.race(socket.close());
  }

  void destroy() => socket.destroy();
}
