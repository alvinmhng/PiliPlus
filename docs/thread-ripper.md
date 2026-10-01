# Thread Ripper playback acceleration

PiliPlus provides a native Dart adaptation of [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper), based on its Range validation, CDN routing, adaptive concurrency, and HLS segment scheduling concepts. The reference was inspected at commit `e64553b1ea911946387a1cf14992ac3fc008e07d` (2026-09-28). Its MIT copyright and license are bundled in `assets/licenses/Bilibili-thread-ripper.LICENSE` and registered with Flutter's license registry.

## Controls

On Android, iOS, Windows, macOS, and Linux, open **Settings → Audio/Video settings → 线程撕裂者 · 多线程加速**. The same panel is available next to CDN settings in the video player settings sheet and in the live player's menu.

- Playback acceleration is opt-in and disabled by default.
- Choose automatic concurrency or a shared limit of 4, 8, 16, or 32 requests. Automatic mode starts at 16, tries higher concurrency when throughput improves, and backs off when servers throttle requests.
- Choose mainland, overseas, or custom official CDN hosts. Custom mode restricts acceleration and fallback to the chosen hosts; an empty custom list uses mainland routes. Signed paths and query strings are preserved.
- Enable live acceleration separately. It prefers an available fMP4 HLS route. Manually selected FLV streams use the existing player route.
- During accelerated playback, the panel shows active requests, concurrency limit, throughput, downloaded bytes, retries, fallback count, and the current node hostname.
- Saving from a player reloads playback and preserves the paused/playing state. VOD also preserves its position. Saving from global settings applies to the next source load.

The existing CDN setting applies when acceleration is off. The audio CDN override is respected. Offline files and casting continue to use their existing sources. The feature optimizes already-authorized media URLs and cannot grant login, subscription, quality, or region permissions.

## Native transport

`ThreadRipperProxy` binds a random port on IPv4 loopback and gives mpv opaque, random session URLs. It does not expose signed URLs in local URLs, accept arbitrary upstream addresses from HTTP clients, or forward account cookies and authorization headers. Outgoing media requests retain the Bilibili referer and user agent and honor the configured application proxy. Browser Origin requests are rejected.

VOD probes a single byte to discover the file length, supports full, bounded, open-ended, suffix, and HEAD requests, then downloads windows of 256 KiB chunks. One FIFO request pool is shared by audio and video. At most 32 chunks (8 MiB) are staged per downstream request, with ordered writes and downstream backpressure. Every chunk must return HTTP 206 with the exact requested Content-Range, total size, and body length. Failures retry another route; unhealthy routes cool down. Nodes without valid Range support use a streamed original-source fallback. When a batch cannot be validated, the connection closes without injecting bad bytes, and a player reopen uses the original route. Seeking cancels disconnected downstream transfers; changing sources or disposing the player closes the old server and cancels all pending transfers.

Live HLS playlists are fetched fresh, and their relative media, init-map, encryption-key, and variant URI references are rewritten. Live segments race a delayed backup node after 400 ms. Up to three announced tail segments are prefetched and shared with foreground requests. No future segment numbers are guessed. The cache is limited to 32 entries, 32 MiB, and 45 seconds; stale segment registrations are removed after 90 seconds, while playlist URLs remain valid for the session. Continuous FLV streams are not divided into VOD byte ranges.

Android permits cleartext only for the loopback endpoint through its network security configuration. iOS declares local networking in App Transport Security. Both macOS debug and release profiles permit the app-owned server. Windows and Linux use the same Dart and mpv transport without a native plugin.

## Verification

Run `flutter test --no-pub` for local transport, CDN/range, settings, and existing account regression tests. Transport fixtures exercise out-of-order chunks, audio/video concurrency, HTTP range/HEAD semantics, invalid nodes, original-stream fallback, cancellation, and HLS URI rewriting/cache reuse without requiring Bilibili credentials.

Run `flutter analyze --no-pub` and the appropriate native build for the target platform. Live Bilibili CDN throughput and device-specific energy/background behavior need verification on the target networks and devices; deterministic fixtures do not establish a speed improvement for every network.

During integration, 24 automated tests passed, along with a Linux debug build and two native mpv smoke tests using generated H.264/AAC and fMP4 HLS fixtures. Native checks covered video/audio playback, seeking, pausing, and HLS segment decoding. Analysis had no errors or warnings and retained the repository's 37 existing informational findings. Anonymous Bilibili API navigation worked, but the public video endpoint returned HTTP 412 from the cloud, preventing a real CDN throughput check. Android, iOS, Windows, and macOS builds and physical-device playback remain unverified in this Linux environment.
