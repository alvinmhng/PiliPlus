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

  List<Uri> _liveCandidates(_LiveAsset parent, Uri uri, String reference) {
    final child = Uri.parse(reference);
    // Explicit absolute references carry their own node/path/signature. Moving
    // them to a backup host can invalidate the URL, including same-host links.
    if (child.isAbsolute || child.hasAuthority) return [uri];
    // API routes may use different playlist directories and ports. Resolve the
    // original relative text separately rather than copying the winning path.
    return {
      uri,
      for (final route in parent.candidates) route.resolveUri(child),
    }.toList(growable: false);
  }

  Future<void> _serveLive(
    HttpRequest request,
    _Downstream response,
    _LiveAsset asset,
    _Transfer transfer,
  ) async {
    asset.touchedAt = _clock.elapsedMilliseconds;
    if (!asset.playlist) {
      return _serveLiveSegment(request, response, asset, transfer);
    }
    // Playlists are live snapshots: never cache them between player requests.
    final result = await _liveRace(
      asset.candidates,
      maximum: 1024 * 1024,
      owner: transfer,
      priority: 120,
    );
    transfer.check();
    final source = utf8.decode(result.$1);
    if (!source.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('Invalid HLS playlist');
    }
    final text = _rewritePlaylist(source, asset, result.$2);
    final bytes = Uint8List.fromList(utf8.encode(text));
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    _status = '直播 HLS 节点加速';
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

  Future<void> _serveLiveSegment(
    HttpRequest request,
    _Downstream response,
    _LiveAsset asset,
    _Transfer transfer,
  ) async {
    final entry = _liveSegment(asset.session, asset.uri, asset.candidates);
    entry.consumers++;
    // A requested prefetched segment is urgent even if its attempts are still
    // waiting for slots. Sharing its future must not retain background priority.
    entry.foreground = true;
    for (final child in entry.transfer.children) {
      _pool.promote(child, priority: 120);
    }
    try {
      await transfer.race(entry.headers.future);
      entry.check();
      final header = request.headers.value(HttpHeaders.rangeHeader);
      // A suffix/range needs the final size. Chunked full responses can stream
      // immediately without waiting for EOF just to discover Content-Length.
      if ((header != null || request.method == 'HEAD') && entry.total == null) {
        await transfer.race(entry.bytes);
      }
      final total = entry.total;
      final range = total == null
          ? null
          : MediaByteRange.fromHeader(header, total);
      if (total != null && range == null) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..contentLength = 0
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        return;
      }
      response
        ..statusCode = header == null
            ? HttpStatus.ok
            : HttpStatus.partialContent
        ..contentLength = range?.length ?? -1
        ..headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (header != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range!.start}-${range.end}/$total',
        );
      }
      // mpv's five-second network timeout also applies before response headers.
      response.add(const []);
      await response.flush();
      if (request.method == 'HEAD') return;
      var cursor = range?.start ?? 0;
      final end = range?.end;
      while (end == null || cursor <= end) {
        transfer.check();
        final changed = entry.changed;
        entry.check();
        if (cursor < entry.length) {
          final bytes = entry.slice(
            cursor,
            end == null ? entry.length : math.min(entry.length, end + 1),
          );
          response.add(bytes);
          await response.flush();
          cursor += bytes.length;
        } else if (entry.finished) {
          break;
        } else {
          await transfer.race(changed);
        }
      }
      if (end == null || end == entry.total! - 1) {
        // Sending the last announced byte can precede the reader's EOF event.
        // Keep the shared job alive until it validates and caches the full body.
        await transfer.race(entry.bytes);
      }
    } finally {
      entry.consumers--;
      if (entry.consumers == 0 && !entry.prefetched && !entry.finished) {
        // A disconnected foreground request must not download the rest of a
        // segment that nobody wants. Announced shared prefetch remains bounded.
        entry.transfer.cancel();
      }
      _pruneLiveCache(asset.session);
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
      final candidates = _liveCandidates(parent, uri, value);
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
          prefetch: true,
        ).bytes.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
          session.prefetchActive--;
          _pumpPrefetch(session);
        }),
      );
    }
  }

  _LiveCacheEntry _liveSegment(
    _LiveSession session,
    Uri uri,
    List<Uri> candidates, {
    bool prefetch = false,
  }) {
    _pruneLiveCache(session);
    if (session.cache[uri] case final entry?
        when !entry.transfer.cancelled || entry.finished) {
      return entry;
    }
    final entry = _LiveCacheEntry(
      _clock.elapsedMilliseconds,
      _newTransfer(),
      prefetched: prefetch,
    );
    session.cache[uri] = entry;
    final future = _liveRace(
      candidates,
      maximum: 8 * 1024 * 1024,
      owner: entry.transfer,
      priority: prefetch ? 30 : 120,
      entry: entry,
    ).then((value) => value.$1);
    // Observe prefetch failures even if the player never requests the segment.
    unawaited(
      future.then<void>(
        (bytes) {
          entry.complete(bytes);
          _endTransfer(entry.transfer);
          _pruneLiveCache(session);
        },
        onError: (Object error, StackTrace stack) {
          entry.fail(error, stack);
          _endTransfer(entry.transfer);
          if (session.cache[uri] == entry) session.cache.remove(uri);
        },
      ),
    );
    return entry;
  }

  void _pruneLiveCache(_LiveSession session) {
    final now = _clock.elapsedMilliseconds;
    void remove(Uri uri) {
      final entry = session.cache.remove(uri)!;
      if (!entry.finished) entry.transfer.cancel();
    }

    final expired = session.cache.entries
        .where(
          (item) => item.value.consumers == 0 && now - item.value.at > 45000,
        )
        .map((item) => item.key)
        .toList();
    for (final uri in expired) {
      remove(uri);
    }
    int size = session.cache.values.fold(0, (sum, entry) => sum + entry.size);
    while (session.cache.length > 32 || size > 32 * 1024 * 1024) {
      final victim = session.cache.entries
          .where((item) => item.value.consumers == 0)
          .firstOrNull;
      if (victim == null) break;
      size -= victim.value.size;
      remove(victim.key);
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
    _Transfer? owner,
    int priority = 120,
    _LiveCacheEntry? entry,
  }) async {
    if (_closed) throw StateError('Transport closed');
    final routes = _ordered(candidates).take(4).toList();
    if (routes.isEmpty) throw const HttpException('No live routes');
    final winner = Completer<(Uint8List, Uri)>();
    final transfers = <_Transfer>[];
    int next = 0;
    int pending = 0;
    final startedAt = _clock.elapsedMilliseconds;
    var progressAt = startedAt;
    Timer? hedge;

    void launch() {
      if (_closed ||
          owner?.cancelled == true ||
          winner.isCompleted ||
          next >= routes.length) {
        return;
      }
      final uri = routes[next++];
      final transfer = _newTransfer(owner);
      transfers.add(transfer);
      pending++;
      int status = 0;
      unawaited(
        _pool
            .run(
              transfer,
              () async {
                final upstream = await _open(transfer, uri);
                try {
                  final response = upstream.response;
                  status = response.statusCode;
                  if (response.statusCode != HttpStatus.ok &&
                      response.statusCode != HttpStatus.partialContent) {
                    throw const HttpException('Live node unavailable');
                  }
                  final range = MediaContentRange.parse(
                    response.headers.value(HttpHeaders.contentRangeHeader),
                  );
                  if (response.statusCode == HttpStatus.partialContent &&
                      (range == null ||
                          range.start != 0 ||
                          range.end != range.total - 1 ||
                          (response.contentLength >= 0 &&
                              response.contentLength != range.total))) {
                    throw const FormatException('Incomplete live segment');
                  }
                  if (response.contentLength > maximum ||
                      (range != null && range.total > maximum)) {
                    throw const FormatException('Live response too large');
                  }
                  final expected = response.contentLength >= 0
                      ? response.contentLength
                      : range?.total;
                  if (expected == 0) {
                    throw const FormatException('Empty live segment');
                  }
                  entry?.setHeaders(expected);
                  var received = 0;
                  final bytes = await _read(
                    upstream,
                    transfer,
                    maximum,
                    expected: expected,
                    onChunk: (chunk) {
                      final appended = entry?.append(chunk, received);
                      received += chunk.length;
                      if (appended != null && appended > 0) {
                        // Re-reading an exposed prefix on a backup is not new
                        // delivered data; count only its contiguous extension.
                        _delivered(appended);
                      }
                      if (entry == null || (appended ?? 0) > 0) {
                        progressAt = _clock.elapsedMilliseconds;
                      }
                    },
                  );
                  if (bytes.isEmpty) {
                    throw const FormatException('Empty live segment');
                  }
                  entry?.validateComplete(bytes);
                  return (bytes, uri, upstream.watch.elapsedMilliseconds);
                } finally {
                  _release(upstream, transfer);
                }
              },
              priority: entry?.foreground == true ? 120 : priority,
              // Background hedges must leave the reserve available to playback.
              rescue: entry?.foreground == true || priority >= 120,
            )
            .then<void>(
              (value) {
                pending--;
                if (!winner.isCompleted) {
                  _success(
                    value.$2,
                    value.$1.length,
                    value.$3,
                    liveMedia: entry != null,
                  );
                  winner.complete((value.$1, value.$2));
                }
              },
              onError: (Object error) {
                pending--;
                if (winner.isCompleted || owner?.cancelled == true) return;
                if (_closed) {
                  winner.completeError(StateError('Transport closed'));
                  return;
                }
                _retries++;
                _failure(uri, status: status);
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
    hedge = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (winner.isCompleted || next >= routes.length) {
        hedge?.cancel();
        return;
      }
      final now = _clock.elapsedMilliseconds;
      final urgent = entry?.foreground == true || priority >= 120;
      final quietFor = now - progressAt;
      final primary = _health['live:${routes.first.authority}'];
      // Try a second route on a cold long download to learn its throughput.
      // Thereafter healthy continuous progress avoids duplicating every segment.
      final explore =
          entry != null &&
          next == 1 &&
          now - startedAt >= 400 &&
          (primary == null ||
              primary.speed == 0 ||
              now - primary.measuredAt >= 90000);
      if (quietFor >= (urgent ? 120 : 400) || explore) launch();
    });
    try {
      final result = await (owner?.race(winner.future) ?? winner.future);
      if (entry == null) _delivered(result.$1.length);
      return result;
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
  _LiveCacheEntry(this.at, this.transfer, {required this.prefetched})
    : foreground = !prefetched {
    // Foreground consumers wait on progress rather than the final future.
    // Observe failures even when no consumer needs the completed cache value.
    unawaited(bytes.then<void>((_) {}, onError: (Object _) {}));
  }
  final int at;
  final _Transfer transfer;
  final bool prefetched;
  bool foreground;
  int consumers = 0;
  int? total;
  int length = 0;
  int get size => length;
  bool finished = false;
  Object? _error;
  StackTrace? _stack;
  final headers = Completer<void>();
  final _complete = Completer<Uint8List>();
  final _chunks = <Uint8List>[];
  final _offsets = <int>[];
  var _changed = Completer<void>();
  Future<Uint8List> get bytes => _complete.future;
  Future<void> get changed => _changed.future;

  void _notify() {
    _changed.complete();
    _changed = Completer<void>();
  }

  void setHeaders(int? expected) {
    if (expected != null) {
      if ((total != null && total != expected) || expected < length) {
        throw const FormatException('Inconsistent live segment length');
      }
      total = expected;
    }
    if (!headers.isCompleted) headers.complete();
  }

  int append(List<int> chunk, int offset) {
    final end = offset + chunk.length;
    if (total != null && end > total!) {
      throw const FormatException('Live segment exceeds declared length');
    }
    final overlap = math.min(length, end);
    if (offset < overlap) {
      final existing = slice(offset, overlap);
      for (var i = 0; i < existing.length; i++) {
        if (existing[i] != chunk[i]) {
          throw const FormatException('Live backup differs from exposed bytes');
        }
      }
    }
    if (end <= length) return 0;
    if (offset > length) {
      throw const FormatException('Noncontiguous live segment');
    }
    final data = Uint8List.fromList(chunk.sublist(length - offset));
    _offsets.add(length);
    _chunks.add(data);
    length += data.length;
    _notify();
    return data.length;
  }

  Uint8List slice(int start, int end) {
    final result = BytesBuilder(copy: false);
    for (var i = 0; i < _chunks.length; i++) {
      final base = _offsets[i];
      final chunk = _chunks[i];
      if (base >= end) break;
      if (base + chunk.length <= start) continue;
      result.add(
        Uint8List.sublistView(
          chunk,
          math.max(0, start - base),
          math.min(chunk.length, end - base),
        ),
      );
    }
    return result.takeBytes();
  }

  void complete(Uint8List value) {
    total = value.length;
    length = value.length;
    _chunks
      ..clear()
      ..add(value);
    _offsets
      ..clear()
      ..add(0);
    finished = true;
    if (!headers.isCompleted) headers.complete();
    _complete.complete(value);
    _notify();
  }

  void validateComplete(Uint8List value) {
    if ((total != null && value.length != total) || value.length < length) {
      throw const FormatException('Truncated live backup');
    }
    // Freeze an unknown length before another racing callback can extend it.
    total ??= value.length;
  }

  void fail(Object error, StackTrace stack) {
    _error = error;
    _stack = stack;
    finished = true;
    if (!headers.isCompleted) headers.complete();
    _complete.completeError(error, stack);
    _notify();
  }

  void check() {
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
  }
}
