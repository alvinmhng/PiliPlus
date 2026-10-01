import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/proxy.dart';
import 'package:flutter_test/flutter_test.dart';

final _media = Uint8List.fromList(
  List.generate(32768, (i) => (i * 37 + i ~/ 256) % 256),
);

class _Node {
  _Node({
    this.ignoreRange = false,
    this.corruptChunks = false,
    this.corruptAfter = 0,
    this.probeDelay = Duration.zero,
    this.segmentDelay = Duration.zero,
    this.chunkDelay = const Duration(milliseconds: 10),
    this.probeGate,
    this.beforeChunk,
    this.writeBody,
    Uint8List? media,
  }) : media = media ?? _media;
  final Uint8List media;
  final bool ignoreRange;
  final bool corruptChunks;
  final int corruptAfter;
  final Duration probeDelay;
  final Duration segmentDelay;
  final Duration chunkDelay;
  final Future<void>? probeGate;
  final Future<void> Function(int start, int end)? beforeChunk;
  final Future<bool> Function(HttpResponse, int, int, Uint8List)? writeBody;
  late HttpServer server;
  int active = 0;
  int peak = 0;
  int requests = 0;
  int chunks = 0;
  final seenRanges = <(int, int)>[];
  final seenHeaders = <HttpHeaders>[];
  final paths = <String>[];
  final connections = <int>{};
  final chunkStarted = Completer<void>();
  final probeStarted = Completer<void>();

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
  }

  Future<void> _serve(HttpRequest request) async {
    requests++;
    connections.add(request.connectionInfo!.remotePort);
    paths.add(request.uri.path);
    seenHeaders.add(request.headers);
    active++;
    if (active > peak) peak = active;
    try {
      final response = request.response;
      if (request.uri.path.endsWith('.m3u8')) {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:1\n'
          '#EXT-X-MAP:URI="init.mp4?token=init"\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:1,\n1.m4s?token=one\n#EXTINF:1,\n2.m4s?token=two\n',
        );
      } else if (request.uri.path.endsWith('.m4s') ||
          request.uri.path.endsWith('init.mp4') ||
          request.uri.path.endsWith('key.bin')) {
        await Future<void>.delayed(segmentDelay);
        response
          ..contentLength = 64
          ..add(_media.sublist(0, 64));
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range?.startsWith('bytes=0-') == true) {
          if (!probeStarted.isCompleted) probeStarted.complete();
          await Future<void>.delayed(probeDelay);
          await probeGate;
        }
        final match = range == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        int start = match == null ? 0 : int.parse(match[1]!);
        int end = match == null || match[2]!.isEmpty
            ? media.length - 1
            : int.parse(match[2]!);
        if (end >= media.length) end = media.length - 1;
        if (ignoreRange) {
          start = 0;
          end = media.length - 1;
        }
        if (range != null && !ignoreRange) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${corruptChunks && end > start && start >= corruptAfter ? start + 1 : start}-$end/${media.length}',
          );
        }
        if (end > start && !ignoreRange) {
          chunks++;
          seenRanges.add((start, end));
          if (!chunkStarted.isCompleted) chunkStarted.complete();
          // Finish later chunks first, exercising response reassembly.
          await Future<void>.delayed(
            start % 4096 == 0 ? chunkDelay * 2 : chunkDelay,
          );
          await beforeChunk?.call(start, end);
        }
        response
          ..contentLength = end - start + 1
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        if (request.method != 'HEAD') {
          final handled = await writeBody?.call(response, start, end, media);
          if (handled != true) response.add(media.sublist(start, end + 1));
        }
      }
      await response.close();
    } catch (_) {
      // Expected when a seek or proxy disposal aborts upstream sockets.
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      active--;
    }
  }

  Future<void> close() => server.close(force: true);
}

class _DelayedClient implements HttpClient {
  _DelayedClient(this.delay);
  final Duration delay;
  final _delegate = HttpClient();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    await Future<void>.delayed(delay);
    return _delegate.openUrl(method, uri);
  }

  @override
  set autoUncompress(bool value) => _delegate.autoUncompress = value;
  @override
  set connectionTimeout(Duration? value) => _delegate.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => _delegate.idleTimeout = value;
  @override
  set maxConnectionsPerHost(int? value) =>
      _delegate.maxConnectionsPerHost = value;
  @override
  set findProxy(String Function(Uri)? value) => _delegate.findProxy = value;
  @override
  void close({bool force = false}) => _delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(HttpClientResponse, Uint8List)> _get(
  HttpClient client,
  String url, {
  String? range,
  String method = 'GET',
  String? origin,
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  if (origin != null) request.headers.set('origin', origin);
  final response = await request.close();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
  }
  return (response, bytes.takeBytes());
}

void main() {
  group('CDN and Range contracts', () {
    test('canonical peer paths become official CDN URLs with HTTPS ports', () {
      const source =
          'https://p2p.mcdn.bilivideo.cn:8443/upgcxcode/1/2/video.m4s?os=mcdn&sign=a%2Bdef';
      final routes = ThreadRipperCdn.resolve([source], ThreadRipperOptions());
      expect(routes, hasLength(ThreadRipperCdn.mainlandHosts.length));
      for (final route in routes) {
        expect(ThreadRipperCdn.mainlandHosts, contains(route.host));
        expect(route.port, 443);
        expect(route.query, Uri.parse(source).query);
        expect(route.path, Uri.parse(source).path);
      }
      expect(
        ThreadRipperCdn.resolve([
          source.replaceFirst('/upgcxcode/1/2/', '/v1/resource/'),
        ], ThreadRipperOptions()),
        isEmpty,
      );
    });

    test('signed URLs retain their exact path and query across CDN routes', () {
      const url =
          'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/01/02/a.m4s?sign=a%2Fb&expires=99&flag';
      final routes = ThreadRipperCdn.resolve([url], ThreadRipperOptions());
      expect(routes.first.host, ThreadRipperCdn.mainlandHosts.first);
      for (final route in routes) {
        expect(route.path, '/upgcxcode/01/02/a.m4s');
        expect(route.query, 'sign=a%2Fb&expires=99&flag');
        expect(route.port, 443);
      }
    });

    test('custom mode confines routes to selected official hosts', () {
      final options = ThreadRipperOptions(
        mode: ThreadRipperCdnMode.custom,
        customHosts: [
          'https://upos-sz-mirrorali.bilivideo.com',
          'upos-sz-mirrorali.bilivideo.com',
          'attacker.example',
        ],
      );
      final routes = ThreadRipperCdn.resolve([
        'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/a.mp4?signature=secret',
      ], options);
      expect(routes.map((uri) => uri.host).toSet(), {
        'upos-sz-mirrorali.bilivideo.com',
      });
      expect(options.customHosts.length, 1);
    });

    test('invalid custom hosts and foreign media never get signed URLs', () {
      for (final value in [
        'http://upos-sz-mirrorali.bilivideo.com',
        'upos-sz-mirrorali.bilivideo.com:8443',
        'upos-sz-mirrorali.bilivideo.com/path',
        'user@upos-sz-mirrorali.bilivideo.com',
        'bilivideo.com.evil.example',
        'https://localhost',
      ]) {
        expect(ThreadRipperCdn.normalizeHost(value), isNull);
      }
      expect(
        ThreadRipperCdn.resolve([
          'https://example.com/video.mp4',
        ], ThreadRipperOptions()),
        isEmpty,
      );
      expect(
        ThreadRipperCdn.resolve(['file:///video.mp4'], ThreadRipperOptions()),
        isEmpty,
      );
      expect(ThreadRipperOptions(concurrency: 999).automatic, isTrue);
    });

    test('single, open, suffix, and unsatisfiable player ranges', () {
      expect(MediaByteRange.fromHeader('bytes=8-', 20)!.length, 12);
      expect(MediaByteRange.fromHeader('bytes=-6', 20)!.start, 14);
      expect(MediaByteRange.fromHeader('bytes=0-99', 20)!.end, 19);
      expect(MediaByteRange.fromHeader(null, 20)!.length, 20);
      for (final header in [
        'bytes=20-',
        'bytes=8-3',
        'bytes=-0',
        'bytes=-',
        'bytes=0-2,4-5',
        'garbage',
      ]) {
        expect(MediaByteRange.fromHeader(header, 20), isNull);
      }
      expect(MediaContentRange.parse('bytes 0-2/2'), isNull);
      expect(MediaContentRange.parse('bytes 2-1/9'), isNull);
      expect(MediaContentRange.parse('bytes 0-2/*'), isNull);
    });
  });

  group('loopback media transport', () {
    late _Node node;
    late ThreadRipperProxy proxy;
    late HttpClient client;
    int recoveries = 0;

    setUp(() async {
      recoveries = 0;
      node = _Node();
      await node.start();
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 4),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        chunkBytes: 1024,
        clientFactory: HttpClient.new,
        onFallback: () => recoveries++,
      );
      await proxy.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.dispose();
      await node.close();
    });

    test(
      'initial GET combines metadata and media, and reuses connections',
      () async {
        await proxy.dispose();
        int clientsCreated = 0;
        proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(enabled: true, concurrency: 4),
          userAgent: 'PiliPlus-Test',
          referer: 'https://www.bilibili.com',
          clientFactory: () {
            clientsCreated++;
            return HttpClient();
          },
        );
        await proxy.start();
        final source = Uint8List.fromList(
          List.generate(2 * 1024 * 1024, (i) => (i * 37) % 251),
        );
        final large = _Node(media: source);
        await large.start();
        try {
          final (_, bytes) = await _get(
            client,
            proxy.addVod([large.uri('/video')]),
          );
          expect(bytes, source);
          expect(large.seenHeaders.first.value('range'), 'bytes=0-65535');
          expect(
            large.seenHeaders.where(
              (h) => h.value('range') == 'bytes=0-0',
            ),
            isEmpty,
          );
          expect(clientsCreated, 1);
          expect(large.connections.length, lessThanOrEqualTo(3));
          expect(large.connections.length, lessThan(large.requests));
          final ranges = large.seenRanges.toList()
            ..sort((a, b) => a.$1.compareTo(b.$1));
          for (var i = 1; i < ranges.length; i++) {
            expect(ranges[i].$1, ranges[i - 1].$2 + 1);
          }
        } finally {
          await large.close();
        }
      },
    );

    test('connect and headers share one first-byte deadline', () async {
      await proxy.dispose();
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 4),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        chunkBytes: 1024,
        firstByteTimeout: const Duration(milliseconds: 180),
        clientFactory: () => _DelayedClient(const Duration(milliseconds: 100)),
      );
      await proxy.start();
      final slowHead = _Node(chunkDelay: const Duration(milliseconds: 90));
      final fastHead = _Node(chunkDelay: const Duration(milliseconds: 5));
      await slowHead.start();
      await fastHead.start();
      try {
        final (_, bytes) = await _get(
          client,
          proxy.addVod([slowHead.uri('/video'), fastHead.uri('/video')]),
          range: 'bytes=0-100',
        );
        expect(bytes, _media.sublist(0, 101));
        expect(fastHead.requests, greaterThan(0));
        expect(slowHead.requests, 1);
      } finally {
        await slowHead.close();
        await fastHead.close();
      }
    });

    test('timed-out openUrl is aborted when it completes late', () async {
      await proxy.dispose();
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 4),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        firstByteTimeout: const Duration(milliseconds: 50),
        clientFactory: () => _DelayedClient(const Duration(milliseconds: 200)),
      );
      await proxy.start();
      final (response, bytes) = await _get(
        client,
        proxy.addVod([node.uri('/video')]),
      );
      expect(response.statusCode, HttpStatus.badGateway);
      expect(bytes, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(node.requests, 0);
    });

    test('refills the window before its slowest sibling completes', () async {
      final releaseSibling = Completer<void>();
      final refillStarted = Completer<void>();
      final delayed = _Node(
        beforeChunk: (start, end) async {
          if (start == 3072) await releaseSibling.future;
          if (start == 4096 && !refillStarted.isCompleted) {
            refillStarted.complete();
          }
        },
      );
      await delayed.start();
      try {
        final pending = _get(client, proxy.addVod([delayed.uri('/video')]));
        try {
          await refillStarted.future.timeout(const Duration(seconds: 1));
        } finally {
          releaseSibling.complete();
        }
        expect((await pending).$2, _media);
      } finally {
        if (!releaseSibling.isCompleted) releaseSibling.complete();
        await delayed.close();
      }
    });

    test('saturated primaries leave capacity for successful backups', () async {
      await proxy.dispose();
      int peak = 0;
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 8),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        chunkBytes: 1024,
        clientFactory: HttpClient.new,
        onActiveRequestsChanged: (active) {
          if (active > peak) peak = active;
        },
      );
      await proxy.start();
      final release = Completer<void>();
      final stalled = _Node(probeGate: release.future);
      await stalled.start();
      try {
        final results = await Future.wait(
          List.generate(
            8,
            (i) => _get(
              client,
              proxy.addVod([stalled.uri('/video$i'), node.uri('/video$i')]),
              range: 'bytes=0-1023',
            ),
          ),
        ).timeout(const Duration(seconds: 2));
        for (final result in results) {
          expect(result.$2, _media.sublist(0, 1024));
        }
        expect(peak, lessThanOrEqualTo(8));
        expect(stalled.probeStarted.isCompleted, isTrue);
        expect(node.requests, greaterThanOrEqualTo(8));
      } finally {
        release.complete();
        await stalled.close();
      }
    });

    test(
      'disconnect stops a multi-window download without another seek',
      () async {
        final source = Uint8List(6 * 1024 * 1024);
        final large = _Node(media: source);
        await large.start();
        Socket? socket;
        try {
          final uri = Uri.parse(proxy.addVod([large.uri('/video')]));
          socket = await Socket.connect(uri.host, uri.port)
            ..write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
          await socket.flush();
          await socket.first.timeout(const Duration(seconds: 1));
          socket.destroy();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          final count = large.requests;
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(large.requests, count);
          expect(large.seenRanges.every((r) => r.$2 < 128 * 1024), isTrue);
          final (_, bytes) = await _get(
            client,
            uri.toString(),
            range: 'bytes=900000-900999',
          );
          expect(bytes, source.sublist(900000, 901000));
        } finally {
          socket?.destroy();
          await large.close();
        }
      },
    );

    test(
      'new seek cancels the old socket even while it remains open',
      () async {
        final source = Uint8List(6 * 1024 * 1024);
        final large = _Node(media: source);
        await large.start();
        Socket? socket;
        try {
          final uri = Uri.parse(proxy.addVod([large.uri('/video')]));
          socket = await Socket.connect(uri.host, uri.port);
          final started = Completer<void>();
          final ended = Completer<void>();
          int received = 0;
          socket
            ..listen(
              (bytes) {
                received += bytes.length;
                if (!started.isCompleted) started.complete();
              },
              onError: (Object _) {
                if (!ended.isCompleted) ended.complete();
              },
              onDone: () {
                if (!ended.isCompleted) ended.complete();
              },
            )
            ..write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
          await socket.flush();
          await started.future.timeout(const Duration(seconds: 1));
          final (_, bytes) = await _get(
            client,
            uri.toString(),
            range: 'bytes=900000-900999',
          );
          expect(bytes, source.sublist(900000, 901000));
          await ended.future.timeout(const Duration(seconds: 1));
          expect(received, lessThan(source.length));
        } finally {
          socket?.destroy();
          await large.close();
        }
      },
    );

    test(
      'interrupted validated ranges resume without repeating bytes',
      () async {
        await proxy.dispose();
        proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(enabled: true, concurrency: 4),
          userAgent: 'PiliPlus-Test',
          referer: 'https://www.bilibili.com',
          clientFactory: HttpClient.new,
        );
        await proxy.start();
        final source = Uint8List.fromList(
          List.generate(1024 * 1024, (i) => (i * 37) % 251),
        );
        final interruptedEnds = <int>{};
        final interrupted = _Node(
          media: source,
          writeBody: (response, start, end, media) async {
            if (start >= 65536 &&
                end - start + 1 > 65536 &&
                interruptedEnds.add(end)) {
              response.add(media.sublist(start, start + 65536));
              await response.flush();
              (await response.detachSocket(writeHeaders: false)).destroy();
              return true;
            }
            return false;
          },
        );
        await interrupted.start();
        try {
          final (_, bytes) = await _get(
            client,
            proxy.addVod([interrupted.uri('/video')]),
          );
          expect(bytes, source);
          expect(interruptedEnds, isNotEmpty);
          expect(
            interrupted.seenRanges.any(
              (a) => interrupted.seenRanges.any(
                (b) => a.$2 == b.$2 && b.$1 == a.$1 + 65536,
              ),
            ),
            isTrue,
          );
        } finally {
          await interrupted.close();
        }
      },
    );

    test(
      'backup resumes bytes already received from a stalled primary',
      () async {
        await proxy.dispose();
        proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(enabled: true, concurrency: 4),
          userAgent: 'PiliPlus-Test',
          referer: 'https://www.bilibili.com',
          clientFactory: HttpClient.new,
        );
        await proxy.start();
        final source = Uint8List.fromList(
          List.generate(1024 * 1024, (i) => (i * 37) % 251),
        );
        final release = Completer<void>();
        final stalled = _Node(
          media: source,
          writeBody: (response, start, end, media) async {
            if (start >= 65536 && end - start + 1 > 65536) {
              response.add(media.sublist(start, start + 65536));
              await response.flush();
              await release.future;
              return true;
            }
            return false;
          },
        );
        final backup = _Node(media: source);
        await stalled.start();
        await backup.start();
        try {
          final (_, bytes) = await _get(
            client,
            proxy.addVod([stalled.uri('/video'), backup.uri('/video')]),
          ).timeout(const Duration(seconds: 2));
          expect(bytes, source);
          expect(
            stalled.seenRanges.any(
              (a) => backup.seenRanges.any(
                (b) => a.$2 == b.$2 && b.$1 == a.$1 + 65536,
              ),
            ),
            isTrue,
          );
        } finally {
          release.complete();
          await stalled.close();
          await backup.close();
        }
      },
    );

    test('audio avoids serial tiny range requests', () async {
      await proxy.dispose();
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 8),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        clientFactory: HttpClient.new,
      );
      await proxy.start();
      final large = _Node(media: Uint8List(2 * 1024 * 1024));
      await large.start();
      try {
        final (_, bytes) = await _get(
          client,
          proxy.addVod([large.uri('/audio')], isAudio: true),
        );
        expect(bytes, large.media);
        expect(large.requests, lessThanOrEqualTo(10));
      } finally {
        await large.close();
      }
    });

    test(
      'assembles out-of-order chunks without missing or repeated bytes',
      () async {
        final url = proxy.addVod([node.uri('/video')]);
        final (response, bytes) = await _get(
          client,
          url,
          range: 'bytes=123-16999',
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 123-16999/32768',
        );
        expect(bytes, _media.sublist(123, 17000));
        final ordered = node.seenRanges.toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
        expect(ordered.first.$1, 123);
        expect(ordered.last.$2, 16999);
        for (var i = 1; i < ordered.length; i++) {
          expect(ordered[i].$1, ordered[i - 1].$2 + 1);
        }
        expect(node.peak, greaterThan(1));
        expect(node.peak, lessThanOrEqualTo(4));
        expect(
          node.seenHeaders.every(
            (h) =>
                h.value('cookie') == null && h.value('authorization') == null,
          ),
          isTrue,
        );
        expect(node.seenHeaders.first.value('user-agent'), 'PiliPlus-Test');
      },
    );

    test('audio and video share the total concurrency cap', () async {
      final results = await Future.wait([
        _get(client, proxy.addVod([node.uri('/video')])),
        _get(client, proxy.addVod([node.uri('/audio')])),
      ]);
      expect(results[0].$2, _media);
      expect(results[1].$2, _media);
      expect(node.peak, lessThanOrEqualTo(4));
    });

    test(
      'delivers startup bytes while later ranges are still pending',
      () async {
        final releaseLater = Completer<void>();
        final laterStarted = Completer<void>();
        final delayed = _Node(
          beforeChunk: (start, end) async {
            if (start >= 2048) {
              if (!laterStarted.isCompleted) laterStarted.complete();
              await releaseLater.future;
            }
          },
        );
        await delayed.start();
        try {
          final first = Completer<List<int>>();
          final delivered = BytesBuilder(copy: false);
          final request = await client.getUrl(
            Uri.parse(proxy.addVod([delayed.uri('/video')])),
          );
          final finished = request.close().then((response) async {
            await for (final chunk in response) {
              delivered.add(chunk);
              if (!first.isCompleted && delivered.length >= 2048) {
                first.complete(delivered.toBytes());
              }
            }
          });
          final assertion = expectLater(
            first.future.timeout(const Duration(seconds: 1)),
            completion(_media.sublist(0, 2048)),
          );
          try {
            await laterStarted.future.timeout(const Duration(seconds: 2));
            await assertion;
          } finally {
            releaseLater.complete();
            await finished;
          }
          expect(delivered.takeBytes(), _media);
          expect(delayed.peak, lessThanOrEqualTo(4));
        } finally {
          if (!releaseLater.isCompleted) releaseLater.complete();
          await delayed.close();
        }
      },
    );

    test('slow metadata does not block an available original route', () async {
      final releaseProbe = Completer<void>();
      final delayed = _Node(probeGate: releaseProbe.future);
      await delayed.start();
      try {
        final url = proxy.addVod(
          [
            delayed.uri('/video'),
            delayed.uri('/video-backup-1'),
            delayed.uri('/video-backup-2'),
            delayed.uri('/video-backup-3'),
            node.uri('/video'),
          ],
          fallbackUrls: [node.uri('/video')],
        );
        final assertion = expectLater(
          _get(client, url).timeout(const Duration(seconds: 1)),
          completion(
            isA<(HttpClientResponse, Uint8List)>().having(
              (result) => result.$2,
              'media bytes',
              _media,
            ),
          ),
        );
        try {
          await delayed.probeStarted.future;
          await assertion;
        } finally {
          releaseProbe.complete();
        }
      } finally {
        if (!releaseProbe.isCompleted) releaseProbe.complete();
        await delayed.close();
      }
    });

    test(
      'slow first media bytes race a working backup after metadata',
      () async {
        final releaseFirstChunk = Completer<void>();
        final delayed = _Node(
          beforeChunk: (start, end) async {
            if (start == 0) await releaseFirstChunk.future;
          },
        );
        await delayed.start();
        try {
          final url = proxy.addVod([
            delayed.uri('/video'),
            node.uri('/video'),
          ]);
          final assertion = expectLater(
            _get(client, url).timeout(const Duration(seconds: 1)),
            completion(
              isA<(HttpClientResponse, Uint8List)>().having(
                (result) => result.$2,
                'media bytes',
                _media,
              ),
            ),
          );
          try {
            await delayed.chunkStarted.future;
            await assertion;
          } finally {
            releaseFirstChunk.complete();
          }
          expect(node.seenRanges, contains((0, 1023)));
        } finally {
          if (!releaseFirstChunk.isCompleted) releaseFirstChunk.complete();
          await delayed.close();
        }
      },
    );

    test(
      'HEAD, suffix seeks, and invalid ranges follow HTTP semantics',
      () async {
        final url = proxy.addVod([node.uri('/video')]);
        final (head, headBytes) = await _get(client, url, method: 'HEAD');
        expect(head.contentLength, _media.length);
        expect(headBytes, isEmpty);
        expect(node.chunks, 0);
        final (_, tail) = await _get(client, url, range: 'bytes=-128');
        expect(tail, _media.sublist(_media.length - 128));
        final (bad, bytes) = await _get(client, url, range: 'bytes=999999-');
        expect(bad.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(bytes, isEmpty);
        expect(
          bad.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */32768',
        );
      },
    );

    test(
      'a corrupt CDN range is discarded and retried on a valid backup',
      () async {
        final bad = _Node(corruptChunks: true);
        await bad.start();
        try {
          final (_, bytes) = await _get(
            client,
            proxy.addVod([bad.uri('/video'), node.uri('/video')]),
          );
          expect(bytes, _media);
          expect(bad.chunks, greaterThan(0));
          expect(node.chunks, greaterThan(0));
        } finally {
          await bad.close();
        }
      },
    );

    test(
      'a node ignoring ranges transparently uses the original stream',
      () async {
        final original = _Node(ignoreRange: true);
        await original.start();
        try {
          final (response, bytes) = await _get(
            client,
            proxy.addVod([original.uri('/video')]),
          );
          expect(response.statusCode, HttpStatus.ok);
          expect(bytes, _media);
          expect(original.requests, 2);
        } finally {
          await original.close();
        }
      },
    );

    test(
      'all invalid startup chunk routes fall back in the same request',
      () async {
        final bad = _Node(corruptChunks: true);
        await bad.start();
        try {
          final url = proxy.addVod(
            [bad.uri('/video')],
            fallbackUrls: [node.uri('/video')],
          );
          final (_, original) = await _get(client, url);
          expect(original, _media);
          final (_, bytes) = await _get(client, url, range: 'bytes=4096-');
          expect(bytes, _media.sublist(4096));
        } finally {
          await bad.close();
        }
      },
    );

    test(
      'unknown endpoints and browser requests cannot access media',
      () async {
        final url = proxy.addVod([node.uri('/video')]);
        final (unknown, _) = await _get(
          client,
          Uri.parse(url).replace(path: '/unknown').toString(),
        );
        final (browser, _) = await _get(
          client,
          url,
          origin: 'https://example.com',
        );
        expect(unknown.statusCode, HttpStatus.notFound);
        expect(browser.statusCode, HttpStatus.forbidden);
        expect(node.requests, 0);
        expect(url, isNot(contains('signature')));
      },
    );

    test(
      'disposal cancels in-flight downloads and releases the listening port',
      () async {
        final slow = _Node(chunkDelay: const Duration(seconds: 2));
        await slow.start();
        try {
          final url = proxy.addVod([slow.uri('/video')]);
          final request = _get(client, url);
          final assertion = expectLater(request, throwsA(isA<HttpException>()));
          await slow.chunkStarted.future.timeout(const Duration(seconds: 3));
          await proxy.dispose();
          await assertion;
          expect(slow.chunks, lessThanOrEqualTo(4));
          final rebound = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            Uri.parse(url).port,
          );
          await rebound.close(force: true);
        } finally {
          await slow.close();
        }
      },
    );

    test('legacy multipart sources keep durations and valid EDL URL lengths', () {
      const one =
          'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/a.mp4?sign=one';
      const two =
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/b.mp4?sign=two';
      const edl =
          'edl://!no_chapters;%${one.length}%$one,length=10;%${two.length}%$two,length=20;';
      final wrapped = proxy.wrapSource(edl);
      expect(wrapped, contains(',length=10;'));
      expect(wrapped, contains(',length=20;'));
      for (final match in RegExp(
        r'%(\d+)%(http://[^,;]+)',
      ).allMatches(wrapped)) {
        expect(int.parse(match[1]!), match[2]!.length);
      }
      expect(wrapped, isNot(contains('sign=')));
    });

    test('an interrupted seek cannot poison a shared metadata probe', () async {
      final delayed = _Node(probeDelay: const Duration(milliseconds: 80));
      await delayed.start();
      final firstClient = HttpClient();
      try {
        final url = proxy.addVod([delayed.uri('/video')]);
        final abandoned = expectLater(
          _get(firstClient, url),
          throwsA(isA<HttpException>()),
        );
        await delayed.probeStarted.future;
        firstClient.close(force: true);
        final (_, bytes) = await _get(client, url, range: 'bytes=4096-8191');
        expect(bytes, _media.sublist(4096, 8192));
        await abandoned;
        expect(
          delayed.seenHeaders
              .where((h) => h.value('range') == 'bytes=0-1023')
              .length,
          1,
        );
      } finally {
        firstClient.close(force: true);
        await delayed.close();
      }
    });

    test(
      'seeking cancels old windows and serves the requested new position',
      () async {
        final firstClient = HttpClient();
        try {
          final url = proxy.addVod([node.uri('/video')]);
          final response = await (await firstClient.getUrl(Uri.parse(url)))
              .close();
          await response.first;
          firstClient.close(force: true);
          final (_, bytes) = await _get(
            client,
            url,
            range: 'bytes=16384-17000',
          );
          expect(bytes, _media.sublist(16384, 17001));
          expect(node.chunks, lessThan(32));
        } finally {
          firstClient.close(force: true);
        }
      },
    );

    test(
      'midstream corruption requests recovery without injecting bad bytes',
      () async {
        final bad = _Node(corruptChunks: true, corruptAfter: 4096);
        await bad.start();
        try {
          final url = proxy.addVod(
            [bad.uri('/video')],
            fallbackUrls: [node.uri('/video')],
          );
          final response = await (await client.getUrl(Uri.parse(url))).close();
          final delivered = BytesBuilder(copy: false);
          await expectLater(
            response.forEach(delivered.add),
            throwsA(isA<HttpException>()),
          );
          final validPrefix = delivered.takeBytes();
          // Socket truncation may discard buffered bytes before the client sees
          // them. Any delivered bytes must belong to the validated first window.
          expect(validPrefix.length, lessThanOrEqualTo(4096));
          expect(validPrefix, _media.sublist(0, validPrefix.length));
          expect(recoveries, 1);
          final (_, remaining) = await _get(client, url, range: 'bytes=4096-');
          expect(remaining, _media.sublist(4096));
        } finally {
          await bad.close();
        }
      },
    );

    test('HLS hedges slow segments and uses the winning node', () async {
      final slow = _Node(segmentDelay: const Duration(milliseconds: 800));
      await slow.start();
      try {
        final url = proxy.addLive([
          slow.uri('/live/index.m3u8'),
          node.uri('/live/index.m3u8'),
        ]);
        final (_, bytes) = await _get(client, url);
        final segments = const LineSplitter()
            .convert(utf8.decode(bytes))
            .where((line) => line.startsWith('http'))
            .toList();
        for (final segment in segments) {
          final (_, data) = await _get(client, segment);
          expect(data, _media.sublist(0, 64));
        }
        expect(slow.paths.where((path) => path.endsWith('.m4s')), isNotEmpty);
        expect(
          slow.paths.where(
            (path) => path.endsWith('.m4s') && node.paths.contains(path),
          ),
          isNotEmpty,
        );
      } finally {
        await slow.close();
      }
    });

    test('HLS playlists rewrite init, key, and segment URLs and reuse prefetched bytes', () async {
      final url = proxy.addLive([node.uri('/live/index.m3u8')]);
      final (_, bytes) = await _get(client, url);
      final playlist = utf8.decode(bytes);
      expect(playlist, startsWith('#EXTM3U'));
      expect(playlist, isNot(contains('token=')));
      final attributes = RegExp(r'URI="([^"]+)"')
          .allMatches(playlist)
          .map((match) => match[1]!)
          .toList();
      final segments = const LineSplitter()
          .convert(playlist)
          .where((line) => line.startsWith('http'))
          .toList();
      expect(attributes.length, 2);
      expect(segments.length, 2);
      for (final local in [...attributes, ...segments]) {
        final (_, data) = await _get(client, local);
        expect(data, _media.sublist(0, 64));
      }
      await _get(client, segments.first);
      expect(node.paths.where((path) => path.endsWith('/1.m4s')).length, 1);
      await _get(client, url);
      expect(
        node.paths.where((path) => path.endsWith('/index.m3u8')).length,
        2,
      );
    });
  });
}
