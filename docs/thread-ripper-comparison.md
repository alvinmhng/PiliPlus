# Thread Ripper implementation comparison

Compared on 2026-10-01:

- This fork before integration: [alvinmhng/PiliPlus at 5e4971a3676493f1e222f8015db76c8747178e96][ours].
- Reference: [lemonteaau/PiliPlus at 014cdd38318a41c78aa61254d6adab96d831fcd4][lemon].
- Both share upstream commit `c102a6115c7ac040f6a0c6a1653944b81b82dcb4`. The comparison covers the transport, CDN resolver, automatic concurrency, source wiring, player lifecycle, settings, native loopback permissions, and regression coverage. Unrelated changes in the reference fork were not merged.

**lemonteaau’s implementation has the stronger VOD scheduler. This fork has broader native playback support, better original-route recovery, and more complete controls.** The integrated implementation adopts the VOD improvements while preserving those strengths.

## Findings and decisions

“Ours” in this table means the pinned version before these changes.

| Area | lemonteaau | Ours | Integrated decision |
| --- | --- | --- | --- |
| Initial buffering | Fetches the first 64 KiB as metadata and reuses it as the initial media block. | Probes one byte, then fetches a separate 32 KiB block; this costs another network round trip. | Adopt the combined prefix for initial GETs. Keep one-byte probes for HEAD and first nonzero/suffix reads. Shared metadata survives an abandoned seek. |
| Connection reuse | One persistent HttpClient; successful fully read requests are not aborted. | Creates clients for transfers and startup attempts, and aborts even successful responses. | Adopt session-wide HTTP/TLS reuse. Abort failures and losers, and close the client when the transport ends. |
| Download window | Refills after each emitted piece; bounds video staging around 2 MiB. | Emits ready pieces in order but refills only after the whole batch; may stage 8 MiB per consumer. | Adopt a sliding window with a hard 2 MiB staging budget per VOD request and ordered socket writes. |
| Startup and rescue | Priority queue and reserved rescue connections prevent stalled ordinary requests from occupying every slot. | All work uses one FIFO pool; a backup can be queued behind the stalled requests it should rescue. | Adopt priorities and reserve roughly one eighth of the global limit, at least one slot. Retain the original API route as an eligible startup backup. |
| Audio fairness | Explicit audio budget, overlapping requests, and a 256 KiB minimum reduce latency overhead. | Audio and video share the cap but have no separate budgets or priorities. | Identify audio at source registration, keep two audio pieces in flight, prioritize them over steady video, and retain the shared cap. |
| Chunk size | Adapts to connection measurements and window budget; avoids many tiny sequential audio requests. | Fixed 256 KiB continuation blocks. | Adopt 64 KiB–1 MiB video and 256 KiB–1 MiB audio pieces, also accounting for the window’s connection budget. Keep the initial prefix small. |
| CDN distribution | Smooth weighted assignments, exploration of unknown nodes, and exclusion of exceptionally slow primary nodes. | Sorting by speed makes a single initially measured node dominate; other nodes may never be measured. | Adopt weighted assignments and bounded exploration with stable tie ordering. |
| CDN measurements | Samples at least 48 KiB, remembers authority/path across signature refreshes, and expires samples after 90 seconds. | Host-wide samples never expire and can mix different representations. | Adopt per-track authority/path history and expiry. Also expire speed ordering for backups; the reference’s rescue sort used its stored speed even after the public speed accessor expired it. |
| Failure policy | Distinguishes failed nodes, signed addresses, and node/address pairs; rechecks bans while downloading. | Host-wide cooldowns can penalize unrelated signed URLs; some failures are counted twice. | Adopt scoped failures and recheck eligibility when a queued attempt obtains a slot. Count each live failure once and prune old live route history. |
| Interrupted pieces | Retains a validated contiguous prefix and resumes retries or hedges at the missing offset. | Retries the entire piece. | Adopt prefix resumption at 32 KiB or more, with exact range, total-size, and body validation. Resume only useful partial progress; invalid Range support still reaches our original-route fallback. |
| Automatic concurrency | Player-lived 8/12/16/24/32 ladder driven by buffering, activity, saturation, throughput trials, and 412/429 pushback. Ignores seek/open buffering. | Per-source 16/32 throughput trials forget learned limits when a video changes; requires a 10% gain. | Adopt buffer-aware learning, restart guards, and persistent cooldowns. Retain our 10% gain requirement for eligible saturated trials. Manual limits stay fixed. |
| Seeking and disconnects | Owns the downstream socket and cancels old per-track GETs when a new GET arrives. | Relies on HttpResponse.done, which may not signal a disconnect during a long response. | Adopt socket disconnect detection, cancellation-aware flushes, and replacement of old GETs. Preserve HEAD independence and shared bounded probes. |
| Timeouts | A single first-byte deadline covers connection and response headers. | Connection and response-header waits can each consume the full timeout. | Adopt a shared 5.5-second deadline, 4-second body-stall timeout, and 15-second range-attempt limit. Add cancellation of openUrl calls that complete after timeout; late request cleanup is not explicit in the reference. |
| Original-route recovery | Exhausted VOD retries produce HTTP errors for existing player error handling. | Can stream the original route within the same HTTP response; after a midstream failure reopens at the current position and preserves playback state. | Keep our fallback and recovery. Reject bad bytes before writing; truncate after a committed failure. |
| Live and multipart playback | Acceleration is DASH-only; live and non-DASH media remain native. | Accelerates HLS separately and wraps legacy multipart EDL sources while retaining durations. | Keep HLS rewriting, segment coalescing, bounded announced-segment prefetch/cache, and multipart wrapping. Live foreground work has priority over prefetch. Continuous FLV remains native. |
| Controls and visibility | Global settings, enabled by default, manual limits through 128; changes take effect on a later load. | Opt-in acceleration, separate live toggle, global and player panels, atomic Save/Cancel, validation, playback-state preservation, and live statistics. | Keep our controls and 4/8/16/32 manual limits. Higher manual limits are a tuning option in the reference, rather than an established performance advantage for this bounded native window. |
| Signed URLs and routing | Broader media-host whitelist and donor synthesis improve coverage; custom input normalization extracts a hostname from URLs containing paths, ports, or credentials. | Strict official custom-host validation, canonical path rewriting, scoped custom fallback, browser-Origin rejection, and configured app-proxy support. | Keep our validation and proxy behavior. Add canonical official peer donors, reset peer ports during manual CDN replacement, and adopt the reference’s audio CDN fallback fixes. Opaque peer paths and unsupported host/path combinations remain native. |
| Native permissions | Shares the cross-platform Dart player transport, but the pinned macOS release entitlement lacks permission for an app-owned server. | Includes Android loopback-only cleartext configuration, iOS local-network ATS settings, and macOS server entitlements. | Keep our native integration on Android, iOS, macOS, Windows, and Linux. |
| Validation | Strong reference traces for resolver ordering, weighted assignments, and adaptive concurrency, plus large-file disconnect and partial-resume cases. | Strong original fallback, HLS, settings, range contracts, and native mpv smoke coverage. | Combine the reference traces with our regressions and extend tests for saturation, sliding refill, connection reuse, late connection completion, and large-file seeks. |

Primary code evidence: [their VOD proxy][l-vod], [resolver][l-routes], [automatic concurrency][l-auto], [player integration][l-player], [settings][l-settings], [CDN helper][l-utils], and [tests][l-tests]; [our previous VOD proxy][o-vod], [HLS transport][o-live], [routing model][o-routes], [player integration][o-player], and [settings panel][o-settings].

## Local comparison

The same local HTTP fixture was used for all three implementations: 80 ms response delay, no bandwidth cap, eight shared connections, one media track, and a 2 MiB download. Each implementation ran three times in its own session; the table shows medians. Full response bytes were checked against the fixture.

| Measurement | Ours before | lemonteaau | Combined |
| --- | ---: | ---: | ---: |
| First media body bytes | 212 ms | 127 ms | 125 ms |
| Complete 2 MiB | 322 ms | 229 ms | 224 ms |
| Upstream requests | 10 | 7 | 7 |
| Upstream TCP connections | 10 | 6 | 6 |

The combined version removes our extra startup round trip and repeated connection setup. Its results are comparable to the reference within this small sample’s timing variation; the measurements do not establish that it is faster on every network.

A separate 6 MiB fixture disconnected immediately after the first local socket data. By 500 ms, the previous implementation had issued ranges covering the entire 6 MiB file; the reference had requested about 2.00 MiB and the combined version about 1.73 MiB. These totals include ranges requested before disconnect and count requested lengths, **not bytes actually received from the CDN**. The regression suite also checks that requests stop and that a new seek terminates an old socket still left open.

Raw runs, fixture parameters, and combined-source hashes are in [comparison results](thread-ripper-comparison-results.json). To reproduce with Flutter configured and dependencies available:

```sh
git fetch --no-tags https://github.com/lemonteaau/PiliPlus.git 014cdd38318a41c78aa61254d6adab96d831fcd4
python3 tool/compare_thread_ripper.py
```

The script exports only the two pinned transport implementations to a temporary directory and compares them with the working tree. Its default JSON output is in the system temporary directory; use `--output PATH` to choose another destination. These are simulated local HTTP measurements, not actual Bilibili CDN, TLS, physical-device, or end-to-end player startup measurements. Historical real-network measurements in the reference’s documentation were not used as evidence for this fork.

## Verification and attribution

Verification on 2026-10-01: all 57 Flutter tests passed; the Linux debug build and both native mpv smoke tests passed. Analysis reported no errors or warnings and retained the repository’s 37 pre-existing informational findings.

The integrated test suite checks resolver/assignment/automatic-concurrency reference traces, startup buffering, shared limits and rescue saturation, audio efficiency, socket cancellation, exact resumed bytes, invalid ranges and fallback, HLS rewriting and cache reuse, settings behavior, existing account handling, and fork update checks. Linux mpv smoke tests exercise H.264/AAC EDL playback, seeking, pausing, and fMP4 HLS decoding.

The native platform integration remains shared Dart code. Android, iOS, macOS, Windows, physical-device playback, and real CDN throughput require validation on their target systems and networks.

Resolver/assignment and automatic-concurrency code, CDN helper fixes, and reference fixtures were adapted from the pinned lemonteaau/PiliPlus implementation under this project’s GPL-3.0 license. The original Bilibili-thread-ripper algorithms remain credited with their bundled MIT notice. Browser injection, MSE/SIDX scheduling, website controls, and browser-specific buffer recovery are outside this native transport.

[ours]: https://github.com/alvinmhng/PiliPlus/commit/5e4971a3676493f1e222f8015db76c8747178e96
[lemon]: https://github.com/lemonteaau/PiliPlus/commit/014cdd38318a41c78aa61254d6adab96d831fcd4
[l-vod]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/services/thread_ripper/range_proxy.dart
[l-routes]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/services/thread_ripper/cdn_resolver.dart
[l-auto]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/services/thread_ripper/auto_concurrency.dart
[l-player]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/plugin/pl_player/controller.dart
[l-settings]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/pages/setting/models/video_settings.dart
[l-utils]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/lib/utils/video_utils.dart
[l-tests]: https://github.com/lemonteaau/PiliPlus/blob/014cdd38318a41c78aa61254d6adab96d831fcd4/test/thread_ripper_test.dart
[o-vod]: https://github.com/alvinmhng/PiliPlus/blob/5e4971a3676493f1e222f8015db76c8747178e96/lib/services/thread_ripper/proxy.dart
[o-live]: https://github.com/alvinmhng/PiliPlus/blob/5e4971a3676493f1e222f8015db76c8747178e96/lib/services/thread_ripper/live.dart
[o-routes]: https://github.com/alvinmhng/PiliPlus/blob/5e4971a3676493f1e222f8015db76c8747178e96/lib/models/common/video/thread_ripper.dart
[o-player]: https://github.com/alvinmhng/PiliPlus/blob/5e4971a3676493f1e222f8015db76c8747178e96/lib/plugin/pl_player/controller.dart
[o-settings]: https://github.com/alvinmhng/PiliPlus/blob/5e4971a3676493f1e222f8015db76c8747178e96/lib/pages/setting/widgets/thread_ripper_dialog.dart
