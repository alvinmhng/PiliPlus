part of 'proxy.dart';

/// Live acceleration uses whole HLS segments, never ranges from a changing FLV
/// stream. A delayed backup races slow nodes; only announced segments prefetch.
extension _LiveTransport on ThreadRipperProxy {
  String _addLive(List<Uri> candidates) {
    final session = _LiveSession(candidates);
    return _liveUrl(session, candidates.first, candidates, playlist: true);
  }

  String _liveUrl(
    _LiveSession session,
    Uri uri,
    List<Uri> candidates, {
    bool? playlist,
  }) {
    if (session.localUrls[uri] case final local?) {
      (_assets[Uri.parse(local).path] as _LiveAsset?)?.touchedAt =
          _clock.elapsedMilliseconds;
      return local;
    }
    final isPlaylist = playlist ?? uri.path.toLowerCase().endsWith('.m3u8');
    final asset = _LiveAsset(
      candidates,
      session,
      uri,
      isPlaylist,
      _clock.elapsedMilliseconds,
    );
    final local = _register(asset, isPlaylist ? '.m3u8' : '.m4s');
    session.localUrls[uri] = local;
    return local;
  }

  List<Uri> _liveCandidates(_LiveAsset parent, Uri uri) {
    // URI attributes may name keys or alternate audio on another official host.
    // Keep that original host and do not copy its signature onto unrelated nodes.
    if (uri.host != parent.uri.host) return [uri];
    return [
      for (final route in parent.candidates)
        uri.replace(host: route.host, port: route.port),
    ];
  }

  Future<void> _serveLive(
    HttpRequest request,
    _LiveAsset asset,
    _Transfer transfer,
  ) async {
    asset.touchedAt = _clock.elapsedMilliseconds;
    final response = request.response;
    Uint8List bytes;
    if (asset.playlist) {
      // Playlists are live snapshots: never cache them between player requests.
      final result = await _liveRace(asset.candidates, maximum: 1024 * 1024);
      transfer.check();
      final source = utf8.decode(result.$1);
      if (!source.trimLeft().startsWith('#EXTM3U')) {
        throw const FormatException('Invalid HLS playlist');
      }
      final text = _rewritePlaylist(source, asset, result.$2);
      bytes = Uint8List.fromList(utf8.encode(text));
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/vnd.apple.mpegurl',
      );
      _status = '直播 HLS 节点加速';
    } else {
      bytes = await _liveSegment(asset.session, asset.uri, asset.candidates);
      transfer.check();
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = MediaByteRange.fromHeader(rangeHeader, bytes.length);
    if (range == null) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
      return;
    }
    response
      ..statusCode = rangeHeader == null
          ? HttpStatus.ok
          : HttpStatus.partialContent
      ..contentLength = range.length
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (rangeHeader != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/${bytes.length}',
      );
    }
    if (request.method != 'HEAD') {
      response.add(Uint8List.sublistView(bytes, range.start, range.end + 1));
    }
  }

  String _rewritePlaylist(String source, _LiveAsset asset, Uri fetchedFrom) {
    final announced = <(Uri, List<Uri>)>[];
    String rewrite(String value) {
      final uri = fetchedFrom.resolve(value);
      // The resolver accepts only HTTPS official Bilibili media hosts. Unsupported
      // references remain absolute so that native HLS still handles them correctly.
      final trusted =
          ThreadRipperCdn.normalizeHost(uri.host) != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty;
      // Low-level fixtures registered via addLive may also use their own origin.
      final fixture = clientFactory != null && uri.origin == fetchedFrom.origin;
      if (!trusted && !fixture) return uri.toString();
      final parent = _LiveAsset(
        asset.candidates,
        asset.session,
        fetchedFrom,
        true,
        asset.touchedAt,
      );
      final candidates = _liveCandidates(parent, uri);
      if (RegExp(r'\.(m4s|ts)$', caseSensitive: false).hasMatch(uri.path)) {
        announced.add((uri, candidates));
      }
      return _liveUrl(asset.session, uri, candidates);
    }

    final lines = const LineSplitter().convert(source).map((line) {
      if (line.trim().isEmpty) return line;
      if (!line.startsWith('#')) return rewrite(line.trim());
      // Includes EXT-X-MAP, KEY, MEDIA, and I-FRAME-STREAM-INF attributes.
      return line.replaceAllMapped(
        RegExp(r'URI="([^"]+)"'),
        (match) => 'URI="${rewrite(match[1]!)}"',
      );
    }).toList();
    // The player usually begins at the live edge. Prefetch a short announced tail
    // with at most three jobs, preserving bandwidth for urgent player requests.
    for (final item in announced.skip(math.max(0, announced.length - 3))) {
      if (!asset.session.cache.containsKey(item.$1) &&
          !asset.session.prefetch.any((entry) => entry.$1 == item.$1)) {
        asset.session.prefetch.add(item);
      }
    }
    while (asset.session.prefetch.length > 6) {
      asset.session.prefetch.removeFirst();
    }
    _pumpPrefetch(asset.session);
    return '${lines.join('\n')}\n';
  }

  void _pumpPrefetch(_LiveSession session) {
    while (!_closed &&
        session.prefetchActive < 3 &&
        session.prefetch.isNotEmpty) {
      final (uri, candidates) = session.prefetch.removeFirst();
      session.prefetchActive++;
      unawaited(
        _liveSegment(
          session,
          uri,
          candidates,
        ).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
          session.prefetchActive--;
          _pumpPrefetch(session);
        }),
      );
    }
  }

  Future<Uint8List> _liveSegment(
    _LiveSession session,
    Uri uri,
    List<Uri> candidates,
  ) {
    _pruneLiveCache(session);
    if (session.cache[uri] case final entry?) return entry.bytes;
    final future = _liveRace(
      candidates,
      maximum: 8 * 1024 * 1024,
    ).then((value) => value.$1);
    final entry = _LiveCacheEntry(future, _clock.elapsedMilliseconds);
    session.cache[uri] = entry;
    // Observe prefetch failures even if the player never requests the segment.
    unawaited(
      future.then<void>(
        (bytes) {
          entry.size = bytes.length;
          _pruneLiveCache(session);
        },
        onError: (Object _) {
          if (session.cache[uri] == entry) session.cache.remove(uri);
        },
      ),
    );
    return future;
  }

  void _pruneLiveCache(_LiveSession session) {
    final now = _clock.elapsedMilliseconds;
    session.cache.removeWhere((_, entry) => now - entry.at > 45000);
    int size = session.cache.values.fold(0, (sum, entry) => sum + entry.size);
    while (session.cache.length > 32 || size > 32 * 1024 * 1024) {
      size -= session.cache.remove(session.cache.keys.first)!.size;
    }
  }

  void _pruneLiveAssets() {
    final expired = _assets.entries
        .where(
          (entry) =>
              entry.value is _LiveAsset &&
              !(entry.value as _LiveAsset).playlist &&
              _clock.elapsedMilliseconds -
                      (entry.value as _LiveAsset).touchedAt >
                  90000,
        )
        .map((entry) => entry.key)
        .toList();
    for (final key in expired) {
      final asset = _assets.remove(key) as _LiveAsset;
      asset.session.localUrls.remove(asset.uri);
      _pruneLiveCache(asset.session);
    }
  }

  Future<(Uint8List, Uri)> _liveRace(
    List<Uri> candidates, {
    required int maximum,
  }) async {
    if (_closed) throw StateError('Transport closed');
    final routes = _ordered(candidates).take(4).toList();
    if (routes.isEmpty) throw const HttpException('No live routes');
    final winner = Completer<(Uint8List, Uri)>();
    final transfers = <_Transfer>[];
    int next = 0;
    int pending = 0;
    Timer? hedge;

    void launch() {
      if (_closed || winner.isCompleted || next >= routes.length) return;
      final uri = routes[next++];
      final transfer = _newTransfer();
      transfers.add(transfer);
      pending++;
      final watch = Stopwatch()..start();
      unawaited(
        _pool
            .run(transfer, () async {
              final upstream = await _open(transfer, uri);
              try {
                final response = upstream.response;
                if (response.statusCode != HttpStatus.ok &&
                    response.statusCode != HttpStatus.partialContent) {
                  _failure(uri, status: response.statusCode);
                  throw const HttpException('Live node unavailable');
                }
                final range = MediaContentRange.parse(
                  response.headers.value(HttpHeaders.contentRangeHeader),
                );
                if (response.statusCode == HttpStatus.partialContent &&
                    (range == null ||
                        range.start != 0 ||
                        range.end != range.total - 1)) {
                  throw const FormatException('Incomplete live segment');
                }
                if (response.contentLength > maximum) {
                  throw const FormatException('Live response too large');
                }
                final bytes = await _read(
                  upstream,
                  transfer,
                  maximum,
                  expected: response.contentLength >= 0
                      ? response.contentLength
                      : range?.total,
                );
                if (bytes.isEmpty) {
                  throw const FormatException('Empty live segment');
                }
                _success(uri, bytes.length, watch.elapsedMilliseconds);
                return (bytes, uri);
              } finally {
                upstream.request.abort();
                transfer.requests.remove(upstream.request);
              }
            })
            .then<void>(
              (value) {
                pending--;
                if (!winner.isCompleted) winner.complete(value);
              },
              onError: (Object error) {
                pending--;
                if (winner.isCompleted) return;
                if (_closed) {
                  winner.completeError(StateError('Transport closed'));
                  return;
                }
                _retries++;
                _failure(uri);
                launch();
                if (pending == 0 && next >= routes.length) {
                  winner.completeError(error);
                }
              },
            )
            .whenComplete(() => _endTransfer(transfer)),
      );
    }

    launch();
    hedge = Timer(const Duration(milliseconds: 400), launch);
    try {
      return await winner.future;
    } finally {
      hedge.cancel();
      for (final transfer in transfers) {
        transfer.cancel();
      }
    }
  }
}

class _LiveSession {
  _LiveSession(this.candidates);
  final List<Uri> candidates;
  final localUrls = <Uri, String>{};
  final cache = <Uri, _LiveCacheEntry>{};
  final prefetch = Queue<(Uri, List<Uri>)>();
  int prefetchActive = 0;
}

class _LiveAsset extends _Asset {
  _LiveAsset(
    super.candidates,
    this.session,
    this.uri,
    this.playlist,
    this.touchedAt,
  );
  final _LiveSession session;
  final Uri uri;
  final bool playlist;
  int touchedAt;
}

class _LiveCacheEntry {
  _LiveCacheEntry(this.bytes, this.at);
  final Future<Uint8List> bytes;
  final int at;
  int size = 0;
}
