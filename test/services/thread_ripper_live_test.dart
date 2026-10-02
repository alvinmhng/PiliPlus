import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/proxy.dart';
import 'package:flutter_test/flutter_test.dart';

final _media = Uint8List.fromList(
  List.generate(128 * 1024, (i) => (i * 37 + i ~/ 256) % 256),
);

class _LiveNode {
  _LiveNode({
    required this.references,
    this.serveMedia,
  });

  final List<String> references;
  final Future<void> Function(HttpRequest)? serveMedia;
  final paths = <String>[];
  late HttpServer server;

  Uri get playlist => Uri.parse('http://127.0.0.1:${server.port}/live.m3u8');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
  }

  Future<void> _serve(HttpRequest request) async {
    paths.add(request.uri.path);
    try {
      // Dart otherwise holds the 8 KiB gated prefix in its response buffer even
      // after flush(), which would make the fixture itself delay first bytes.
      request.response.bufferOutput = false;
      if (request.uri.path.endsWith('.m3u8')) {
        request.response
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:1\n'
            '${references.map((path) => '#EXTINF:2,\n$path\n').join()}',
          );
      } else if (serveMedia case final serve?) {
        await serve(request);
      } else {
        request.response
          ..contentLength = _media.length
          ..add(_media);
      }
      await request.response.close();
    } catch (_) {
      // Cancelling a losing CDN or closing a player request aborts its socket.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => server.close(force: true);
}

Future<(HttpClientResponse, Uint8List)> _fetch(
  HttpClient client,
  String url, {
  String method = 'GET',
  String? range,
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  final response = await request.close();
  final bytes = BytesBuilder(copy: false);
  await response.forEach(bytes.add);
  return (response, bytes.takeBytes());
}

Future<List<String>> _segments(HttpClient client, String url) async {
  final (_, bytes) = await _fetch(client, url);
  return const LineSplitter()
      .convert(utf8.decode(bytes))
      .where((line) => line.startsWith('http'))
      .toList();
}

void main() {
  group('live foreground transport', () {
    late ThreadRipperProxy proxy;
    late HttpClient client;
    late List<_LiveNode> nodes;
    late List<Completer<void>> gates;

    setUp(() async {
      nodes = [];
      gates = [];
      proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(enabled: true, concurrency: 8),
        userAgent: 'PiliPlus-Live-Test',
        referer: 'https://www.bilibili.com',
        clientFactory: HttpClient.new,
      );
      await proxy.start();
      client = HttpClient();
    });

    tearDown(() async {
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      client.close(force: true);
      await proxy.dispose();
      for (final node in nodes) {
        await node.close();
      }
    });

    Future<_LiveNode> startNode({
      required List<String> references,
      Future<void> Function(HttpRequest)? serveMedia,
    }) async {
      final node = _LiveNode(references: references, serveMedia: serveMedia);
      nodes.add(node);
      await node.start();
      return node;
    }

    Completer<void> newGate() {
      final gate = Completer<void>();
      gates.add(gate);
      return gate;
    }

    test('streams the first segment bytes before its remaining body finishes', () async {
      final releaseTail = newGate();
      final prefixSent = Completer<void>();
      final node = await startNode(
        // A rewritten .bin reference avoids prefetch, isolating the foreground.
        references: ['first.bin'],
        serveMedia: (request) async {
          request.response
            ..contentLength = _media.length
            ..add(_media.sublist(0, 8192));
          await request.response.flush();
          prefixSent.complete();
          await releaseTail.future;
          request.response.add(_media.sublist(8192));
        },
      );
      final segments = await _segments(client, proxy.addLive([node.playlist]));
      final firstBytes = Completer<void>();
      final collected = BytesBuilder(copy: false);
      final done = () async {
        final request = await client.getUrl(Uri.parse(segments.single));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        await response.forEach((bytes) {
          collected.add(bytes);
          if (!firstBytes.isCompleted) firstBytes.complete();
        });
      }();
      // Observe errors immediately, including if the timing assertion fails.
      unawaited(done.then<void>((_) {}, onError: (Object _) {}));
      try {
        await prefixSent.future.timeout(const Duration(seconds: 2));
        await firstBytes.future.timeout(const Duration(milliseconds: 750));
        expect(releaseTail.isCompleted, isFalse);
        expect(collected.length, greaterThan(0));
        expect(collected.length, lessThan(_media.length));
      } finally {
        releaseTail.complete();
        await done.timeout(const Duration(seconds: 2));
      }
      expect(collected.takeBytes(), _media);
    });

    test('unknown-length live bodies stream before EOF and support subsequent ranges', () async {
      final releaseTail = newGate();
      final node = await startNode(
        references: ['first.bin'],
        serveMedia: (request) async {
          // Omitting Content-Length makes the fixture use chunked encoding.
          request.response.add(_media.sublist(0, 8192));
          await request.response.flush();
          await releaseTail.future;
          request.response.add(_media.sublist(8192));
        },
      );
      final segments = await _segments(client, proxy.addLive([node.playlist]));
      final firstBytes = Completer<void>();
      final collected = BytesBuilder(copy: false);
      final done = () async {
        final request = await client.getUrl(Uri.parse(segments.single));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(response.contentLength, -1);
        await response.forEach((bytes) {
          collected.add(bytes);
          if (!firstBytes.isCompleted) firstBytes.complete();
        });
      }();
      unawaited(done.then<void>((_) {}, onError: (Object _) {}));
      Future<(HttpClientResponse, Uint8List)>? pendingRange;
      try {
        await firstBytes.future.timeout(const Duration(milliseconds: 750));
        expect(releaseTail.isCompleted, isFalse);
        expect(collected.length, lessThan(_media.length));
        // A suffix is requested while the total size is still unknown. It must
        // share the current download and wait for its final size.
        pendingRange = _fetch(client, segments.single, range: 'bytes=-256');
        unawaited(pendingRange.then<void>((_) {}, onError: (Object _) {}));
      } finally {
        releaseTail.complete();
        await done.timeout(const Duration(seconds: 2));
      }
      expect(collected.takeBytes(), _media);
      final (response, bytes) = await pendingRange.timeout(
        const Duration(seconds: 2),
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(bytes, _media.sublist(_media.length - 256));
      expect(node.paths.where((path) => path == '/first.bin').length, 1);
    });

    test('learns the healthy CDN across different segment paths', () async {
      final stalledRoute = newGate();
      const references = ['first.bin', 'second.bin', 'third.bin'];
      int? stalledPort;
      Future<void> serve(HttpRequest request) async {
        final port = request.connectionInfo!.localPort;
        // Whichever origin is chosen initially stalls. This exercises learning
        // without depending on the scheduler's initial candidate order.
        stalledPort ??= port;
        if (port == stalledPort) {
          await stalledRoute.future;
        }
        request.response
          ..contentLength = _media.length
          ..add(_media);
      }

      final first = await startNode(references: references, serveMedia: serve);
      final second = await startNode(references: references, serveMedia: serve);
      final segments = await _segments(
        client,
        proxy.addLive([first.playlist, second.playlist]),
      );
      // A two-node alternating scheduler eventually returns to the stalled
      // origin. Learning must cover the channel, not one segment's path.
      for (final segment in segments) {
        final (_, bytes) = await _fetch(client, segment).timeout(
          const Duration(seconds: 2),
        );
        expect(bytes, _media);
      }
      final stalled = [first, second].singleWhere(
        (node) => node.server.port == stalledPort,
      );
      final healthy = [first, second].singleWhere(
        (node) => node.server.port != stalledPort,
      );
      expect(healthy.paths, contains('/third.bin'));
      expect(stalled.paths, contains('/first.bin'));
      expect(stalled.paths, isNot(contains('/third.bin')));
    });

    test(
      'a failed previously winning authority is skipped on the next segment',
      () async {
        const references = ['first.bin', 'second.bin', 'third.bin'];
        final backupStarted = Completer<void>();
        final releaseBackup = newGate();
        final degraded = await startNode(
          references: references,
          serveMedia: (request) async {
            if (request.uri.path == '/second.bin') {
              request.response
                ..statusCode = HttpStatus.serviceUnavailable
                ..write('overloaded');
              return;
            }
            request.response
              ..contentLength = _media.length
              ..add(_media);
          },
        );
        final backup = await startNode(
          references: references,
          serveMedia: (request) async {
            if (!backupStarted.isCompleted) backupStarted.complete();
            await releaseBackup.future;
            request.response
              ..contentLength = _media.length
              ..add(_media);
          },
        );
        final segments = await _segments(
          client,
          proxy.addLive([degraded.playlist, backup.playlist]),
        );
        final (_, first) = await _fetch(client, segments.first);
        expect(first, _media);
        expect(degraded.paths, contains('/first.bin'));
        expect(backup.paths, isNot(contains('/first.bin')));

        final pendingSecond = _fetch(client, segments[1]);
        unawaited(pendingSecond.then<void>((_) {}, onError: (Object _) {}));
        await backupStarted.future.timeout(const Duration(seconds: 2));
        expect(degraded.paths, contains('/second.bin'));
        releaseBackup.complete();
        final (_, second) = await pendingSecond.timeout(
          const Duration(seconds: 2),
        );
        expect(second, _media);
        final (_, third) = await _fetch(client, segments[2]);
        expect(third, _media);
        expect(backup.paths, contains('/third.bin'));
        expect(degraded.paths, isNot(contains('/third.bin')));
      },
    );

    test('a small media winner is retained across paths despite playlist-only success', () async {
      const references = ['first.bin', 'second.bin'];
      final small = Uint8List.sublistView(_media, 0, 8192);
      final stalledBody = newGate();
      final stalled = await startNode(
        references: references,
        serveMedia: (request) async {
          await stalledBody.future;
          request.response
            ..contentLength = small.length
            ..add(small);
        },
      );
      final healthy = await startNode(
        references: references,
        serveMedia: (request) async {
          request.response
            ..contentLength = small.length
            ..add(small);
        },
      );
      final segments = await _segments(
        client,
        proxy.addLive([stalled.playlist, healthy.playlist]),
      );
      for (final segment in segments) {
        final (_, bytes) = await _fetch(client, segment).timeout(
          const Duration(seconds: 2),
        );
        expect(bytes, small);
      }
      // Both routes have a successful tiny response: the first served only the
      // playlist, the second actually served media below the 48 KiB speed cutoff.
      expect(stalled.paths, contains('/first.bin'));
      expect(stalled.paths, isNot(contains('/second.bin')));
      expect(healthy.paths, contains('/second.bin'));
      expect(stalledBody.isCompleted, isFalse);
    });

    test(
      'continues hedging to a third route while two bodies stay stalled',
      () async {
        final stalledRoutes = newGate();
        int attempts = 0;
        Future<void> serve(HttpRequest request) async {
          if (++attempts <= 2) await stalledRoutes.future;
          request.response
            ..contentLength = _media.length
            ..add(_media);
        }

        final first = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final second = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final third = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final segments = await _segments(
          client,
          proxy.addLive([
            first.playlist,
            second.playlist,
            third.playlist,
          ]),
        );
        final (_, bytes) = await _fetch(client, segments.single).timeout(
          const Duration(milliseconds: 950),
        );
        expect(bytes, _media);
        expect(attempts, 3);
        expect(stalledRoutes.isCompleted, isFalse);
      },
    );

    test(
      'a backup extends a partially streamed segment without duplicate bytes',
      () async {
        final releasePrimary = newGate();
        final primaryPrefix = Completer<void>();
        int attempts = 0;
        Future<void> serve(HttpRequest request) async {
          attempts++;
          request.response.contentLength = _media.length;
          if (attempts == 1) {
            request.response.add(_media.sublist(0, 8192));
            await request.response.flush();
            primaryPrefix.complete();
            await releasePrimary.future;
            request.response.add(_media.sublist(8192));
          } else {
            await primaryPrefix.future;
            request.response.add(_media);
          }
        }

        final first = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final second = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final segments = await _segments(
          client,
          proxy.addLive([first.playlist, second.playlist]),
        );
        final (_, bytes) = await _fetch(client, segments.single).timeout(
          const Duration(milliseconds: 950),
        );
        expect(bytes, _media);
        expect(attempts, 2);
        expect(releasePrimary.isCompleted, isFalse);
      },
    );

    test(
      'a mismatched backup cannot replace bytes already streamed to the player',
      () async {
        final releasePrimary = newGate();
        int attempts = 0;
        Future<void> serve(HttpRequest request) async {
          final attempt = ++attempts;
          request.response.contentLength = _media.length;
          if (attempt == 1) {
            request.response.add(_media.sublist(0, 8192));
            await request.response.flush();
            await releasePrimary.future;
            request.response.add(_media.sublist(8192));
          } else if (attempt == 2) {
            final wrong = Uint8List.fromList(_media);
            wrong[0] ^= 0xff;
            request.response.add(wrong);
          } else {
            request.response.add(_media);
          }
        }

        final first = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final second = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final third = await startNode(
          references: ['first.bin'],
          serveMedia: serve,
        );
        final segments = await _segments(
          client,
          proxy.addLive([first.playlist, second.playlist, third.playlist]),
        );
        final (_, bytes) = await _fetch(client, segments.single).timeout(
          const Duration(milliseconds: 950),
        );
        expect(bytes, _media);
        expect(attempts, 3);
        expect(releasePrimary.isCompleted, isFalse);
      },
    );

    test('a short unknown-length backup cannot truncate a longer live segment', () async {
      final releasePrimary = newGate();
      int attempts = 0;
      Future<void> serve(HttpRequest request) async {
        final attempt = ++attempts;
        if (attempt == 1) {
          request.response
            ..contentLength = _media.length
            ..add(_media.sublist(0, 64 * 1024));
          await request.response.flush();
          await releasePrimary.future;
          request.response.add(_media.sublist(64 * 1024));
        } else if (attempt == 2) {
          // This prefix matches the canonical segment, but its chunked EOF is
          // shorter than both its declared total and the already streamed data.
          request.response.add(_media.sublist(0, 32 * 1024));
        } else {
          request.response
            ..contentLength = _media.length
            ..add(_media);
        }
      }

      final first = await startNode(
        references: ['first.bin'],
        serveMedia: serve,
      );
      final second = await startNode(
        references: ['first.bin'],
        serveMedia: serve,
      );
      final third = await startNode(
        references: ['first.bin'],
        serveMedia: serve,
      );
      final segments = await _segments(
        client,
        proxy.addLive([first.playlist, second.playlist, third.playlist]),
      );
      final (_, bytes) = await _fetch(client, segments.single).timeout(
        const Duration(milliseconds: 950),
      );
      expect(bytes, _media);
      expect(attempts, 3);
      expect(releasePrimary.isCompleted, isFalse);
    });

    test('HEAD waits for unknown-length completion and reports the cached final size', () async {
      final releaseTail = newGate();
      final prefixSent = Completer<void>();
      final node = await startNode(
        references: ['first.bin'],
        serveMedia: (request) async {
          request.response.add(_media.sublist(0, 8192));
          await request.response.flush();
          prefixSent.complete();
          await releaseTail.future;
          request.response.add(_media.sublist(8192));
        },
      );
      final segments = await _segments(client, proxy.addLive([node.playlist]));
      final pendingHead = _fetch(client, segments.single, method: 'HEAD');
      bool headCompleted = false;
      unawaited(
        pendingHead.then<void>(
          (_) => headCompleted = true,
          onError: (Object _) => headCompleted = true,
        ),
      );
      try {
        await prefixSent.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(headCompleted, isFalse);
      } finally {
        releaseTail.complete();
      }
      final (head, headBytes) = await pendingHead.timeout(
        const Duration(seconds: 2),
      );
      expect(head.statusCode, HttpStatus.ok);
      expect(head.contentLength, _media.length);
      expect(headBytes, isEmpty);
      final (_, body) = await _fetch(client, segments.single);
      expect(body, _media);
      expect(node.paths.where((path) => path == '/first.bin').length, 1);
    });

    test(
      'an urgent segment promotes its queued prefetch into the reserved slot',
      () async {
        final releaseBodies = newGate();
        final sevenOccupied = Completer<void>();
        int activeBodies = 0;
        List<String> finalSegments = [];
        for (int channel = 0; channel < 3; channel++) {
          final node = await startNode(
            references: [
              '$channel-first.m4s',
              '$channel-middle.m4s',
              '$channel-tail.m4s',
            ],
            serveMedia: (request) async {
              if (request.uri.path == '/2-tail.m4s') {
                request.response
                  ..contentLength = _media.length
                  ..add(_media);
                return;
              }
              activeBodies++;
              if (activeBodies == 7) sevenOccupied.complete();
              request.response
                ..contentLength = _media.length
                ..add(_media.sublist(0, 8192));
              await request.response.flush();
              await releaseBodies.future;
              request.response.add(_media.sublist(8192));
            },
          );
          finalSegments = await _segments(
            client,
            proxy.addLive([node.playlist]),
          );
        }
        await sevenOccupied.future.timeout(const Duration(seconds: 2));
        // Seven ordinary prefetch requests occupy the normal portion of the
        // eight-slot pool. The urgent tail must be promoted to use the reserve.
        final (_, bytes) = await _fetch(client, finalSegments.last).timeout(
          const Duration(milliseconds: 750),
        );
        expect(bytes, _media);
        expect(releaseBodies.isCompleted, isFalse);
        expect(activeBodies, 7);
      },
    );

    test(
      'a disconnected uncached foreground request cancels its upstream work',
      () async {
        await proxy.dispose();
        int active = 0;
        bool waitingForCancellation = false;
        final inactive = Completer<void>();
        proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(enabled: true, concurrency: 8),
          userAgent: 'PiliPlus-Live-Test',
          referer: 'https://www.bilibili.com',
          clientFactory: HttpClient.new,
          onActiveRequestsChanged: (value) {
            active = value;
            if (waitingForCancellation && value == 0 && !inactive.isCompleted) {
              inactive.complete();
            }
          },
        );
        await proxy.start();
        final releaseTail = newGate();
        final prefixSent = Completer<void>();
        final node = await startNode(
          references: ['first.bin'],
          serveMedia: (request) async {
            request.response
              ..contentLength = _media.length
              ..add(_media.sublist(0, 8192));
            await request.response.flush();
            prefixSent.complete();
            await releaseTail.future;
            request.response.add(_media.sublist(8192));
          },
        );
        final segments = await _segments(
          client,
          proxy.addLive([node.playlist]),
        );
        final local = Uri.parse(segments.single);
        final socket = await Socket.connect(local.host, local.port);
        addTearDown(socket.destroy);
        socket
          ..listen((_) {}, onError: (Object _) {})
          ..write(
            'GET ${local.path} HTTP/1.1\r\nHost: ${local.authority}\r\n'
            'Connection: close\r\n\r\n',
          );
        await socket.flush();
        await prefixSent.future.timeout(const Duration(seconds: 2));
        expect(active, greaterThan(0));
        waitingForCancellation = true;
        socket.destroy();
        await inactive.future.timeout(const Duration(milliseconds: 750));
        expect(releaseTail.isCompleted, isFalse);
      },
    );

    test(
      'completed live cache preserves HEAD, ranges, and exact media bytes',
      () async {
        final node = await startNode(references: ['first.bin']);
        final segments = await _segments(
          client,
          proxy.addLive([node.playlist]),
        );
        final (full, body) = await _fetch(client, segments.single);
        expect(full.statusCode, HttpStatus.ok);
        expect(body, _media);

        final (head, headBody) = await _fetch(
          client,
          segments.single,
          method: 'HEAD',
        );
        expect(head.statusCode, HttpStatus.ok);
        expect(head.contentLength, _media.length);
        expect(headBody, isEmpty);

        final (range, partial) = await _fetch(
          client,
          segments.single,
          range: 'bytes=1234-4321',
        );
        expect(range.statusCode, HttpStatus.partialContent);
        expect(
          range.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 1234-4321/${_media.length}',
        );
        expect(partial, _media.sublist(1234, 4322));

        final (suffix, suffixBytes) = await _fetch(
          client,
          segments.single,
          range: 'bytes=-1024',
        );
        expect(suffix.statusCode, HttpStatus.partialContent);
        expect(suffixBytes, _media.sublist(_media.length - 1024));

        final (invalid, invalidBytes) = await _fetch(
          client,
          segments.single,
          range: 'bytes=${_media.length}-',
        );
        expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(invalidBytes, isEmpty);
        expect(node.paths.where((path) => path == '/first.bin').length, 1);
      },
    );
  });
}
