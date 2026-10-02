import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final primary = Uri.parse(
    'https://d1--cn-gotcha304.bilivideo.com/live-bvc/room/index.m3u8'
    '?deadline=123&upsig=primary%2Fsig%2Bvalue&token=one&token=two',
  );
  final backup = Uri.parse(
    'https://d1--ov-gotcha05.bilivideo.com/live-bvc/room/index.m3u8'
    '?deadline=456&upsig=backup%2Bsig%2Fvalue&token=three',
  );

  for (final mode in [
    ThreadRipperCdnMode.mainland,
    ThreadRipperCdnMode.overseas,
  ]) {
    test('live $mode retains API route order and each signed query', () {
      final routes = ThreadRipperCdn.resolve(
        [primary.toString(), backup.toString(), primary.toString()],
        ThreadRipperOptions(mode: mode),
        live: true,
      );
      expect(routes.map((uri) => uri.toString()), [
        primary.toString(),
        backup.toString(),
      ]);
    });
  }

  test('empty custom live configuration retains API routes', () {
    expect(
      ThreadRipperCdn.resolve(
        [primary.toString(), backup.toString()],
        ThreadRipperOptions(mode: ThreadRipperCdnMode.custom),
        live: true,
      ),
      [primary, backup],
    );
  });

  test('custom live routes stay confined to the explicit hosts', () {
    final custom = ThreadRipperCdn.liveHosts.first;
    final routes = ThreadRipperCdn.resolve(
      [primary.toString(), backup.toString()],
      ThreadRipperOptions(
        mode: ThreadRipperCdnMode.custom,
        customHosts: [custom],
      ),
      live: true,
    );
    expect(routes, [
      primary.replace(host: custom, port: 443),
      backup.replace(host: custom, port: 443),
    ]);
    expect(routes.every((uri) => uri.host == custom), isTrue);
    expect(routes.map((uri) => uri.query), [primary.query, backup.query]);
  });

  test('live resolution leaves FLV and untrusted URLs on the native path', () {
    expect(
      ThreadRipperCdn.resolve(
        [
          primary.replace(path: '/live-bvc/room.flv').toString(),
          primary.replace(scheme: 'http').toString(),
          primary.replace(host: 'video.example.com').toString(),
          primary.replace(userInfo: 'credentials').toString(),
        ],
        ThreadRipperOptions(),
        live: true,
      ),
      isEmpty,
    );
  });
}
