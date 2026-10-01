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
  });
  final bool ignoreRange;
  final bool corruptChunks;
  final int corruptAfter;
  final Duration probeDelay;
  final Duration segmentDelay;
  final Duration chunkDelay;
  late HttpServer server;
  int active = 0;
  int peak = 0;
  int requests = 0;
  int chunks = 0;
  final seenRanges = <(int, int)>[];
  final seenHeaders = <HttpHeaders>[];
  final paths = <String>[];
  final chunkStarted = Completer<void>();
  final probeStarted = Completer<void>();

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
  }

  Future<void> _serve(HttpRequest request) async {
    requests++;
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
        if (range == 'bytes=0-0') {
          if (!probeStarted.isCompleted) probeStarted.complete();
          await Future<void>.delayed(probeDelay);
        }
        final match = range == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        int start = match == null ? 0 : int.parse(match[1]!);
        int end = match == null || match[2]!.isEmpty
            ? _media.length - 1
            : int.parse(match[2]!);
        if (ignoreRange) {
          start = 0;
          end = _media.length - 1;
        }
        if (range != null && !ignoreRange) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${corruptChunks && end > start && start >= corruptAfter ? start + 1 : start}-$end/${_media.length}',
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
        }
        response
          ..contentLength = end - start + 1
          ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        if (request.method != 'HEAD') {
          response.add(_media.sublist(start, end + 1));
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
    test(
      'automatic concurrency keeps useful gains and backs off on throttling',
      () {
        final tuner = ThreadRipperConcurrency()
          ..observe(1024 * 1024, 1000, 5000)
          ..observe(1024 * 1024, 1000, 10000);
        expect(tuner.limit, 32);
        tuner.observe(2 * 1024 * 1024, 1000, 15000);
        expect(tuner.limit, 32);
        tuner.throttle(16000);
        expect(tuner.limit, 16);
        tuner.throttle(17000);
        expect(tuner.limit, 8);
        tuner.observe(8 * 1024 * 1024, 1000, 20000);
        expect(tuner.limit, 8);

        final flat = ThreadRipperConcurrency();
        for (final at in [5000, 10000, 15000]) {
          flat.observe(1024 * 1024, 1000, at);
        }
        expect(flat.limit, 16);
        flat.observe(1024 * 1024, 1000, 20000);
        expect(flat.limit, 16);
        final manual = ThreadRipperConcurrency(concurrency: 4)
          ..observe(1024 * 1024, 1000, 5000)
          ..throttle(10000);
        expect(manual.limit, 4);
      },
    );
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
              .where((h) => h.value('range') == 'bytes=0-0')
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
