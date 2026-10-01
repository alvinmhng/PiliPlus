import 'dart:math' as math;

/// Native adaptation of Bilibili-thread-ripper's Range and CDN logic.
/// See third_party/Bilibili-thread-ripper.LICENSE.
enum ThreadRipperCdnMode {
  mainland('大陆 CDN'),
  overseas('海外 CDN'),
  custom('自定义 CDN');

  const ThreadRipperCdnMode(this.label);
  final String label;
}

class ThreadRipperOptions {
  ThreadRipperOptions({
    this.enabled = false,
    this.liveEnabled = false,
    this.mode = ThreadRipperCdnMode.mainland,
    int concurrency = 0,
    Iterable<String> customHosts = const [],
  }) : concurrency = threadCounts.contains(concurrency) ? concurrency : 0,
       customHosts = customHosts
           .map(ThreadRipperCdn.normalizeHost)
           .whereType<String>()
           .toSet()
           .take(32)
           .toList(growable: false);

  static const threadCounts = [0, 4, 8, 16, 32];
  final bool enabled;
  final bool liveEnabled;
  final ThreadRipperCdnMode mode;

  /// Zero selects automatic concurrency (8–32).
  final int concurrency;
  final List<String> customHosts;
  bool get automatic => concurrency == 0;
}

abstract final class ThreadRipperCdn {
  static const mainlandHosts = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];
  static const overseasHosts = [
    'upos-sz-mirrorcosov.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
    'cn-hk-eq-01-03.bilivideo.com',
  ];
  static const liveHosts = [
    'd1--cn-gotcha204.bilivideo.com',
    'd1--cn-gotcha208.bilivideo.com',
    'd1--ov-gotcha208.bilivideo.com',
    'd1--ov-gotcha208b.bilivideo.com',
  ];

  static final _host = RegExp(
    r'^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+(?:bilivideo\.(?:com|cn|net)|akamaized\.net)$',
    caseSensitive: false,
  );
  static final _media = RegExp(r'\.(?:m4s|mp4|flv)$', caseSensitive: false);

  static String? normalizeHost(String value) {
    value = value.trim().toLowerCase();
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.host.length > 253 ||
        !_host.hasMatch(uri.host)) {
      return null;
    }
    return uri.host;
  }

  static bool isMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      _host.hasMatch(uri.host) &&
      _media.hasMatch(uri.path);

  static bool isLivePlaylist(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      _host.hasMatch(uri.host) &&
      uri.path.toLowerCase().endsWith('.m3u8');

  static bool isPeer(Uri uri) =>
      uri.host.contains('.mcdn.') || uri.host.split('.').first.contains('302');

  /// Only replace ordinary CDN paths; peer resource paths have different signing.
  static List<Uri> resolve(
    Iterable<String> urls,
    ThreadRipperOptions options, {
    bool live = false,
  }) {
    final originals = urls
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where(live ? isLivePlaylist : isMedia)
        .where((uri) => !isPeer(uri))
        .toSet()
        .toList();
    if (originals.isEmpty) return const [];
    final custom =
        options.mode == ThreadRipperCdnMode.custom &&
        options.customHosts.isNotEmpty;
    final hosts = custom
        ? options.customHosts
        : live
        ? liveHosts
              .where(
                (host) => options.mode == ThreadRipperCdnMode.overseas
                    ? host.contains('--ov-')
                    : host.contains('--cn-'),
              )
              .toList()
        : options.mode == ThreadRipperCdnMode.overseas
        ? overseasHosts
        : mainlandHosts;
    final result = <Uri>{
      for (final uri in originals)
        if (custom
            ? hosts.contains(uri.host)
            : options.mode == ThreadRipperCdnMode.overseas
            ? !mainlandHosts.contains(uri.host)
            : hosts.contains(uri.host))
          uri,
    };
    final donors = originals
        .where((uri) => live || uri.path.startsWith('/upgcxcode/'))
        .toList();
    for (final host in hosts) {
      for (final donor in donors) {
        // replace preserves the original signed path and raw query string.
        result.add(donor.replace(host: host, port: 443));
      }
    }
    if (!custom) result.addAll(originals);
    return result.toList(growable: false);
  }
}

/// Throughput trials keep the smallest useful automatic limit. Server pushback
/// immediately reduces load and prevents another increase for 90 seconds.
class ThreadRipperConcurrency {
  ThreadRipperConcurrency({int concurrency = 0})
    : automatic = concurrency == 0,
      limit = concurrency == 0 ? 16 : concurrency;

  final bool automatic;
  int limit;
  double _baseline = 0;
  int _trialFrom = 0;
  int _tunedAt = 0;
  int _restUntil = 0;

  bool observe(int bytes, int elapsedMilliseconds, int now) {
    if (!automatic ||
        elapsedMilliseconds <= 0 ||
        now - _tunedAt < 5000 ||
        now < _restUntil) {
      return false;
    }
    final before = limit;
    final speed = bytes * 1000 / elapsedMilliseconds;
    if (_trialFrom != 0) {
      if (speed < _baseline * 1.1) {
        limit = _trialFrom;
        _restUntil = now + 30000;
      }
      _trialFrom = 0;
    } else if (_baseline > 0 && limit < 32) {
      _trialFrom = limit;
      limit = math.min(32, limit * 2);
    }
    _baseline = speed;
    _tunedAt = now;
    return before != limit;
  }

  void throttle(int now) {
    if (!automatic) return;
    limit = math.max(8, limit ~/ 2);
    _trialFrom = 0;
    _restUntil = now + 90000;
  }
}

class MediaByteRange {
  const MediaByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
  String get header => 'bytes=$start-$end';

  /// Single ranges only, including open-ended and suffix requests from mpv.
  static MediaByteRange? fromHeader(String? header, int total) {
    if (total <= 0) return null;
    if (header == null) return MediaByteRange(0, total - 1);
    final match = RegExp(
      r'^bytes=(\d*)-(\d*)$',
      caseSensitive: false,
    ).firstMatch(header.trim());
    if (match == null) return null;
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    if (first == null) {
      return last == null || last <= 0
          ? null
          : MediaByteRange(math.max(0, total - last), total - 1);
    }
    if (first >= total || (last != null && last < first)) return null;
    return MediaByteRange(first, math.min(last ?? total - 1, total - 1));
  }
}

class MediaContentRange extends MediaByteRange {
  const MediaContentRange(super.start, super.end, this.total);
  final int total;

  static MediaContentRange? parse(String? value) {
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        total == null ||
        start < 0 ||
        end < start ||
        total <= end) {
      return null;
    }
    return MediaContentRange(start, end, total);
  }
}
