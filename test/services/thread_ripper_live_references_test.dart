import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReferenceNode {
  _ReferenceNode(this.handler);
  final Future<void> Function(HttpRequest) handler;
  final requests = <Uri>[];
  late HttpServer server;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_serve(request)));
  }

  Future<void> _serve(HttpRequest request) async {
    requests.add(request.uri);
    try {
      await handler(request);
      await request.response.close();
    } catch (_) {
      // Losing races and transport disposal may abort the fixture socket.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => server.close(force: true);
}

void _playlist(HttpResponse response, String child) {
  response
    ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
    ..write('#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n$child\n');
}

Future<Uint8List> _get(HttpClient client, String url) async {
  final response = await (await client.getUrl(Uri.parse(url))).close();
  expect(response.statusCode, HttpStatus.ok);
  final bytes = BytesBuilder(copy: false);
  await response.forEach(bytes.add);
  return bytes.takeBytes();
}

Future<String> _child(HttpClient client, String url) async {
  final bytes = await _get(client, url);
  return const LineSplitter()
      .convert(utf8.decode(bytes))
      .singleWhere((line) => line.startsWith('http'));
}

void main() {
  late ThreadRipperProxy proxy;
  late HttpClient client;
  late List<_ReferenceNode> nodes;
  final media = Uint8List.fromList(List.generate(128, (index) => index));

  setUp(() async {
    nodes = [];
    proxy = ThreadRipperProxy(
      options: ThreadRipperOptions(enabled: true, concurrency: 4),
      userAgent: 'PiliPlus-Live-Reference-Test',
      referer: 'https://www.bilibili.com',
      clientFactory: HttpClient.new,
    );
    await proxy.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.dispose();
    for (final node in nodes) {
      await node.close();
    }
  });

  Future<_ReferenceNode> startNode(
    Future<void> Function(HttpRequest) handler,
  ) async {
    final node = _ReferenceNode(handler);
    nodes.add(node);
    await node.start();
    return node;
  }

  test(
    'relative children resolve each API playlist directory and raw query',
    () async {
      const reference =
          'segment.bin?sig=child%2Fvalue%2Btail&token=one&token=two';
      final primary = await startNode((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          _playlist(request.response, reference);
        } else {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        }
      });
      final backup = await startNode((request) async {
        if (request.uri.path == '/backup/segment.bin') {
          request.response
            ..contentLength = media.length
            ..add(media);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      });
      final local = proxy.addLive([
        primary.uri('/primary/index.m3u8?sig=primary'),
        backup.uri('/backup/index.m3u8?sig=backup'),
      ]);
      final segment = await _child(client, local);
      expect(await _get(client, segment), media);
      final requested = backup.requests.single;
      expect(requested.path, '/backup/segment.bin');
      expect(requested.query, Uri.parse(reference).query);
      expect(primary.requests.last.path, '/primary/segment.bin');
    },
  );

  for (final networkPath in [false, true]) {
    test(
      'explicit ${networkPath ? 'protocol-relative' : 'absolute'} same-origin child keeps its only route',
      () async {
        late _ReferenceNode primary;
        primary = await startNode((request) async {
          if (request.uri.path.endsWith('.m3u8')) {
            final absolute = primary.uri(
              '/explicit/segment.bin?sig=exact%2Fnode',
            );
            _playlist(
              request.response,
              networkPath
                  ? absolute.toString().substring(5)
                  : absolute.toString(),
            );
          } else {
            // Enough delay to expose accidental cloning onto the backup node.
            await Future<void>.delayed(const Duration(milliseconds: 350));
            request.response
              ..contentLength = media.length
              ..add(media);
          }
        });
        final backup = await startNode((request) async {
          request.response
            ..contentLength = media.length
            ..add(media);
        });
        final segment = await _child(
          client,
          proxy.addLive([
            primary.uri('/primary/index.m3u8'),
            backup.uri('/backup/index.m3u8'),
          ]),
        );
        expect(await _get(client, segment), media);
        expect(backup.requests, isEmpty);
        expect(
          primary.requests.last.toString(),
          '/explicit/segment.bin?sig=exact%2Fnode',
        );
      },
    );
  }
}
