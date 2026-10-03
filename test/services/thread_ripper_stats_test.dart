import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('closing the panel from a statistics callback stops sampling', () async {
    final samplingTimers = <Timer>[];
    await runZoned(
      () async {
        final proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(concurrency: 4),
          userAgent: 'PiliPlus-Test',
          referer: 'https://www.bilibili.com',
        );
        final published = Completer<void>();
        void listener() {
          proxy.stats.removeListener(listener);
          published.complete();
        }

        try {
          await proxy.start();
          proxy.stats.addListener(listener);
          await published.future.timeout(const Duration(seconds: 5));
          expect(samplingTimers.single.isActive, isFalse);
        } finally {
          await proxy.dispose();
        }
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(milliseconds: 500)) {
            samplingTimers.add(timer);
          }
          return timer;
        },
      ),
    );
  });

  test('statistics sampling exists only while the panel is observed', () async {
    final samplingTimers = <Timer>[];
    await runZoned(
      () async {
        final proxy = ThreadRipperProxy(
          options: ThreadRipperOptions(concurrency: 4),
          userAgent: 'PiliPlus-Test',
          referer: 'https://www.bilibili.com',
        );
        int notifications = 0;
        void first() => notifications++;
        void second() {}
        try {
          await proxy.start();
          expect(samplingTimers, isEmpty);
          expect(proxy.stats.value.threadLimit, 4);

          proxy.stats.addListener(first);
          expect(samplingTimers, hasLength(1));
          proxy.stats.addListener(second);
          expect(samplingTimers, hasLength(1));
          await Future<void>.delayed(const Duration(milliseconds: 600));
          expect(notifications, greaterThan(0));

          proxy.stats.removeListener(first);
          expect(samplingTimers.single.isActive, isTrue);
          proxy.stats.removeListener(second);
          expect(samplingTimers.single.isActive, isFalse);
          expect(proxy.stats.value.bytesPerSecond, 0);

          proxy.stats.addListener(first);
          expect(samplingTimers, hasLength(2));
          await proxy.dispose();
          expect(samplingTimers.every((timer) => !timer.isActive), isTrue);
        } finally {
          await proxy.dispose();
        }
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(milliseconds: 500)) {
            samplingTimers.add(timer);
          }
          return timer;
        },
      ),
    );
  });

  test(
    'unobserved counters are fresh when opening and reopening the panel',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write('#EXTM3U\n#EXT-X-VERSION:3\n');
        await request.response.close();
      });
      final proxy = ThreadRipperProxy(
        options: ThreadRipperOptions(concurrency: 4),
        userAgent: 'PiliPlus-Test',
        referer: 'https://www.bilibili.com',
        clientFactory: HttpClient.new,
      );
      final client = HttpClient();
      final measuredSpeed = Completer<void>();
      final idleSpeed = Completer<void>();
      void listener() {
        if (proxy.stats.value.bytesPerSecond > 0) {
          if (!measuredSpeed.isCompleted) measuredSpeed.complete();
        } else if (measuredSpeed.isCompleted && !idleSpeed.isCompleted) {
          idleSpeed.complete();
        }
      }

      try {
        await proxy.start();
        final uri = Uri.parse(
          proxy.addLive([
            Uri.parse('http://127.0.0.1:${server.port}/live.m3u8'),
          ]),
        );
        Future<void> request() async {
          final response = await (await client.getUrl(uri)).close();
          expect(response.statusCode, HttpStatus.ok);
          expect(await utf8.decoder.bind(response).join(), contains('#EXTM3U'));
        }

        await request();
        expect(proxy.stats.value.lastHost, '127.0.0.1');
        expect(proxy.stats.value.status, '直播 HLS 节点加速');
        expect(proxy.stats.value.activeThreads, 0);
        final firstBytes = proxy.stats.value.downloadedBytes;
        expect(firstBytes, greaterThan(0));

        proxy.stats.addListener(listener);
        await request();
        expect(proxy.stats.value.downloadedBytes, firstBytes * 2);
        await measuredSpeed.future.timeout(const Duration(seconds: 5));
        expect(proxy.stats.value.bytesPerSecond, greaterThan(0));
        await idleSpeed.future.timeout(const Duration(seconds: 5));
        expect(proxy.stats.value.bytesPerSecond, 0);
        proxy.stats.removeListener(listener);
        await request();
        proxy.stats.addListener(listener);
        expect(proxy.stats.value.lastHost, '127.0.0.1');
        expect(proxy.stats.value.downloadedBytes, firstBytes * 3);
        expect(proxy.stats.value.bytesPerSecond, 0);
        expect(proxy.stats.value.threadLimit, 4);
        proxy.stats.removeListener(listener);
      } finally {
        client.close(force: true);
        await proxy.dispose();
        await server.close(force: true);
      }
    },
  );
}
