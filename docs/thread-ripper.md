# Thread Ripper playback acceleration

PiliPlus provides a native Dart adaptation of [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper), based on its Range validation, CDN routing, adaptive concurrency, and HLS segment scheduling concepts. The reference was inspected at commit `e64553b1ea911946387a1cf14992ac3fc008e07d` (2026-09-28). The VOD scheduler also incorporates the implementation and reference traces from [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) at commit `014cdd38318a41c78aa61254d6adab96d831fcd4` under GPL-3.0. Thread Ripper’s MIT copyright and license are bundled in `assets/licenses/Bilibili-thread-ripper.LICENSE` and registered with Flutter's license registry.

## Controls

On Android, iOS, Windows, macOS, and Linux, open **Settings → Audio/Video settings → 线程撕裂者 · 多线程加速**. The same panel is available next to CDN settings in the video player settings sheet and in the live player's menu.

- Playback acceleration is opt-in and disabled by default.
- Choose automatic concurrency or a shared limit of 4, 8, 16, or 32 requests. Automatic mode starts at 8 and uses the 8/12/16/24/32 ladder. Low buffer pressure or a playback stall triggers a trial increase; eligible saturated trials without a 10% throughput gain roll back. Server throttling (412/429) reduces the limit and imposes a 180-second cooldown. Learned limits and cooldowns survive video changes in the same player. Opening, reloading, seeking, and paused playback do not trigger buffer-pressure increases.
- Choose mainland, overseas, or custom official CDN hosts. VOD uses the regional presets; live uses the complete signed routes supplied by the API. Custom mode restricts acceleration and fallback to the chosen hosts; an empty custom list uses mainland VOD routes and the API's live routes. Signed paths and query strings are preserved.
- Enable live acceleration separately. It prefers an available fMP4 HLS route. Manually selected FLV streams use the existing player route.
- During accelerated playback, the panel shows active requests, concurrency limit, throughput, downloaded bytes, retries, fallback count, and the current node hostname.
- Saving from a player reloads playback and preserves the paused/playing state. VOD also preserves its position. Saving from global settings applies to the next source load.

The existing CDN setting applies when acceleration is off. The audio CDN override is respected. Offline files and casting continue to use their existing sources. The feature optimizes already-authorized media URLs and cannot grant login, subscription, quality, or region permissions.

## Native transport

`ThreadRipperProxy` binds a random port on IPv4 loopback and gives mpv opaque, random session URLs. It does not expose signed URLs in local URLs, accept arbitrary upstream addresses from HTTP clients, or forward account cookies and authorization headers. Outgoing media requests retain the Bilibili referer and user agent and honor the configured application proxy. Browser Origin requests are rejected.

An initial VOD GET from byte zero fetches up to 64 KiB once, validates it, and uses the same bytes for file-length discovery and the demuxer prefix. HEAD and first requests away from byte zero use a one-byte probe. Full, bounded, open-ended, suffix, and HEAD semantics are supported. Short reads are flushed immediately. Metadata and startup ranges try backups at 120 ms intervals, prefer an available original route as a backup, and cancel losing attempts. Custom mode confines both acceleration and fallback to the selected hosts.

Audio, video, startup, retries, and live work share one priority connection pool. Ordinary requests leave approximately one eighth of the limit available for rescue attempts (at least one slot). Audio uses two in-flight pieces and a higher priority than steady video downloads. A sliding window refills after each ordered write; it stages at most 2 MiB of VOD data per downstream request and applies socket backpressure. Video pieces adapt between 64 KiB and 1 MiB; audio pieces are at least 256 KiB to amortize high network latency. Window size and connection budget also influence piece size.

A persistent session HttpClient honors system proxy settings and normal TLS validation. Fully consumed successful requests keep their connections reusable; failed, cancelled, and losing requests are aborted. Connecting and receiving response headers share one 5.5-second deadline, stalled bodies time out after 4 seconds, and each range attempt has a 15-second overall deadline. A late connection completion after a timeout is also aborted.

Per-track routing uses smooth weighted assignments: measured fast nodes receive more pieces, extremely slow nodes are excluded from primary assignments, and unknown nodes retain exploration opportunities. Throughput samples require at least 48 KiB, survive signed-query refreshes for the same authority and path, and expire after 90 seconds. Failures distinguish nodes, signed addresses, and node/address pairs; routes are checked again after a queued attempt obtains its slot. Normal pieces hedge after a measured 250–900 ms delay; the first continuation pieces use 120 ms. Verified contiguous prefixes of at least 32 KiB can resume across retries or backup nodes. Only complete winning pieces contribute to delivered-throughput statistics.

Every piece must return HTTP 206 with the exact requested Content-Range, consistent total size, and exact body length. Wrong headers, oversized bodies, and invalid prefixes are discarded. A useful interrupted prefix can retry up to three times; unsupported Range responses reach the existing streamed original-source fallback promptly. An initial failure can fall back within the same HTTP response. After valid bytes have been sent, failure truncates the connection and requests a player reopen on the original route, preserving position and paused/playing state.

The local transport owns its downstream sockets so a client disconnect cancels upstream requests and queued attempts immediately. A new GET for the same VOD track also cancels the old GET, covering mpv’s practice of opening a new seek before closing the old connection. HEAD requests do not interrupt playback. Shared bounded metadata probes survive an abandoned request, so later seeks can reuse their result. Changing sources or disposing the player closes the old server and cancels its work.

Canonical `/upgcxcode/` paths from official peer hosts can be synthesized onto official CDN hosts, with the standard HTTPS port and unchanged signed query. Opaque peer resource paths remain native. The existing manual CDN helper also clears peer ports on replacement and honors the audio CDN bypass.

Live HLS playlists are fetched fresh. Relative media, init-map, encryption-key, and variant references resolve separately against each supplied playlist route, preserving its directory and port; absolute references keep their exact signed route. Segment headers and contiguous body bytes are forwarded immediately while a shared download fills the cache. A backup must match every prefix byte already exposed and the known total size before it can extend or complete the segment. Unknown-length responses also stream immediately; suffix/range requests wait for a final size when necessary.

Live routing remembers the most recent media winner across segment paths, with expiring throughput samples. Network/server failures cool down the authority, while signature failures remain scoped to their URL. Stalled foreground downloads keep trying remaining backups at 120 ms intervals; prefetch uses a slower interval and leaves rescue capacity for playback. Healthy continuous downloads avoid redundant backups after the route is learned. A requested prefetched segment promotes its queued attempts to foreground priority. Up to three announced tail segments are prefetched and shared with playback; no future segment numbers are guessed.

Unconsumed cache storage is limited to 32 entries, 32 MiB, and 45 seconds. Active streams retain their shared buffers until their consumers finish, with an 8 MiB limit per segment. Evicting unfinished unconsumed entries cancels their work, and disconnecting an unshared foreground request cancels its download. Stale segment registrations are removed after 90 seconds, while playlist URLs remain valid for the session. Continuous FLV streams are not divided into VOD byte ranges.

Android permits cleartext only for the loopback endpoint through its network security configuration. iOS declares local networking in App Transport Security. Both macOS debug and release profiles permit the app-owned server. Windows and Linux use the same Dart and mpv transport without a native plugin.

## Verification

Run `flutter test --no-pub` for local transport, CDN/range, settings, and existing account regression tests. Transport fixtures exercise out-of-order chunks, audio/video concurrency, HTTP range/HEAD semantics, invalid nodes, original-stream fallback, cancellation, and HLS URI rewriting/cache reuse without requiring Bilibili credentials. Startup regressions hold later ranges, metadata probes, or the initial media block open to verify that ready bytes and working backup routes let playback proceed.

Run `flutter analyze --no-pub` and the appropriate native build for the target platform. Live Bilibili CDN throughput and device-specific energy/background behavior need verification on the target networks and devices; deterministic fixtures do not establish a speed improvement for every network.

Verification on 2026-10-02: all 78 Flutter tests and four native mpv playback checks passed. Analysis reported no errors or warnings and retained 37 pre-existing informational findings. Native checks cover H.264/AAC EDL playback, seeking, pausing, fMP4 HLS decoding, and progressive playback while a segment remains in flight beyond mpv's five-second network timeout.
