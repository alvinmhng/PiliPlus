// Reference traces from lemonteaau/PiliPlus at 014cdd38318a (GPL-3.0).
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup ordering does not reuse an expired speed sample', () {
    var now = DateTime.fromMillisecondsSinceEpoch(100000);
    final a = Uri.parse('https://a.bilivideo.com/v.m4s');
    final b = a.replace(host: 'b.bilivideo.com');
    final routes = ThreadRipperRoutes([a, b], now: () => now)
      ..recordSuccess(a, 100000)
      ..recordSuccess(b, 50000);
    expect(routes.rescueCandidates().first, a);
    now = now.add(const Duration(seconds: 89));
    routes.sample(b, 50000);
    now = now.add(const Duration(seconds: 2));
    expect(routes.rescueCandidates().first, b);
  });

  test('empty-response bans distinguish nodes, addresses, and pairs', () {
    final bans = ThreadRipperBanList();
    final a = Uri.parse('https://a.bilivideo.com/video.m4s?sign=one');
    final b = a.replace(host: 'b.bilivideo.com');
    bans
      ..failure(a, status: 403)
      ..failure(a, status: 403);
    expect(bans.allows(a), isTrue);
    bans.success(b);
    expect(bans.allows(a), isFalse);
    expect(bans.allows(b), isTrue);
    bans.success(a.replace(query: 'sign=two'));
    expect(bans.allows(a), isFalse);
    expect(bans.allows(a.replace(query: 'sign=two')), isTrue);
    final partial = ThreadRipperBanList()
      ..failure(a, received: 10)
      ..failure(a, received: 10);
    expect(partial.allows(a), isTrue);
  });

  test(
    'resolver follows original JavaScript reference traces in both regions',
    () {
      final fixtures = jsonDecode(
        File('test/fixtures/ripper_resolver.json').readAsStringSync(),
      ) as List;
      for (final fixture in fixtures) {
        var now = DateTime.fromMillisecondsSinceEpoch(100000);
        final rep = fixture['representation'];
        final originals = <String>[
          rep['baseUrl'],
          ...List<String>.from(rep['backupUrl']),
        ];
        final overseas = fixture['mode'] == 'overseas';
        final urls = (fixture['urls'] as List)
            .cast<String>()
            .map(Uri.parse)
            .toList();
        final resolver = ThreadRipperRoutes(
          urls,
          originals: originals.map(Uri.parse).toList(),
          overseas: overseas,
          now: () => now,
        );
        for (final step in fixture['steps']) {
          final args = step['args'] as List;
          List<Uri>? result;
          switch (step['op']) {
            case 'startupCandidates':
              result = resolver.startupCandidates();
            case 'rangeCandidates':
              result = resolver.rangeCandidates();
            case 'rescueCandidates':
              result = resolver.rescueCandidates();
            case 'ordered':
              result = resolver.ordered(args[0]);
            case 'success':
              resolver.success(
                Uri.parse(args[0]),
                args[1],
                const Duration(seconds: 1),
              );
            case 'failure':
              resolver.failure(
                Uri.parse(args[0]),
                status: args[1]['status'],
                received: args[2],
              );
            case 'sample':
              resolver.sample(Uri.parse(args[0]), (args[1] as num).toDouble());
            case 'advance':
              now = now.add(Duration(milliseconds: args[0]));
            case 'speed':
              expect(
                resolver.speed(Uri.parse(args[0])),
                closeTo(step['expected'], 0.01),
              );
          }
          if (result != null) {
            expect(
              result.map((u) => u.toString()).toList(),
              step['expected'],
              reason: '${fixture['mode']} ${step['op']}',
            );
          }
        }
      }
    },
  );

  test('weighted assignments match upstream including sparse exploration', () {
    final fixtures = jsonDecode(
      File('test/fixtures/ripper_assignments.json').readAsStringSync(),
    ) as List;
    final assignments = ThreadRipperAssignments();
    for (final fixture in fixtures) {
      final urls = (fixture['urls'] as List)
          .cast<String>()
          .map(Uri.parse)
          .toList();
      final resolver = ThreadRipperRoutes(urls);
      for (var i = 0; i < urls.length; i++) {
        resolver.recordSuccess(
          urls[i],
          (fixture['speeds'][i] as num).toDouble(),
        );
      }
      for (final step in fixture['steps']) {
        expect(
          assignments
              .assign(urls, resolver, step['count'])
              .map((u) => u.toString())
              .toList(),
          step['expected'],
        );
      }
    }
  });

  test('speed survives signature refresh but expires and tiny tails do not renew it', () {
    var now = DateTime.fromMillisecondsSinceEpoch(100000);
    final url = Uri.parse('https://a.bilivideo.com/v.m4s?sign=old');
    final fresh = url.replace(query: 'sign=new');
    final resolver = ThreadRipperRoutes([url], now: () => now)
      ..success(url, 100000, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 89));
    resolver.success(fresh, 1024, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 2));
    expect(resolver.speed(fresh), 0);
  });
}
