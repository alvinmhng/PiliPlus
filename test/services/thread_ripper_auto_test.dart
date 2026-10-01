// Reference traces from lemonteaau/PiliPlus at 014cdd38318a (GPL-3.0).
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paused and restart buffering never increase concurrency', () {
    var now = 5000;
    final auto = ThreadRipperConcurrency(now: () => now);
    for (; now <= 10000; now += 250) {
      auto
        ..activity()
        ..buffer(1, false);
    }
    expect(auto.limit, 8);
  });

  test('learned limit and rate-limit cooldown survive video changes', () {
    var now = 5000;
    final auto = ThreadRipperConcurrency(now: () => now)..stall();
    expect(auto.limit, 12);
    now = 8000;
    auto.stall();
    expect(auto.limit, 16);
    auto
      ..pushback()
      ..newSession();
    expect(auto.limit, 12);
    now = 12000;
    expect(auto.stall(), isFalse);
    expect(auto.limit, 12);
    now = 189000;
    expect(auto.stall(), isTrue);
    expect(auto.limit, 16);
  });

  for (final (trialBytes, expected) in [(250000, 8), (400000, 12)]) {
    test('throughput trial with $trialBytes bytes keeps only useful gains', () {
      var now = 5000;
      final auto = ThreadRipperConcurrency(now: () => now)..demand(8, 8, 5);
      for (now = 5250; now <= 10000; now += 250) {
        auto.delivered(250000);
      }
      now = 10000;
      expect(auto.slow(), isTrue);
      expect(auto.limit, 12);
      auto.demand(12, 12, 5);
      for (now = 10250; now <= 20000; now += 250) {
        auto.delivered(trialBytes);
      }
      expect(auto.limit, expected);
      if (expected == 8) {
        now = 23000;
        expect(auto.slow(), isFalse);
        expect(auto.limit, 8);
      }
    });
  }

  test('manual concurrency remains fixed under buffer and server pressure', () {
    var now = 5000;
    final manual = ThreadRipperConcurrency(concurrency: 4, now: () => now);
    for (; now < 20000; now += 250) {
      manual
        ..demand(4, 4, 20)
        ..activity()
        ..buffer(0, true)
        ..delivered(250000)
        ..stall()
        ..pushback();
    }
    expect(manual.limit, 4);
  });

  test(
    'automatic concurrency preserves reference buffer-pressure and rate-limit behavior',
    () {
      var now = 5000;
      final auto = ThreadRipperConcurrency(now: () => now);
      final steps = jsonDecode(
        File('test/fixtures/ripper_auto.json').readAsStringSync(),
      ) as List;
      for (final step in steps) {
        now = step['at'];
        final args = step['args'] as List;
        switch (step['op']) {
          case 'demand':
            auto.demand(args[0], args[1], args[2]);
          case 'activity':
            auto.activity();
          case 'delivered':
            auto.delivered((args[0] as num).toInt());
          case 'stall':
            auto.stall();
          case 'pushback':
            auto.pushback();
          case 'newSession':
            auto.newSession();
          case 'buffer':
            auto.buffer((args[0] as num).toDouble(), args[1]);
        }
        expect(auto.limit, step['threads'], reason: '${step['op']} at $now');
      }
    },
  );
}
