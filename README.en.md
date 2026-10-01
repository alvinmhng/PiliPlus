# PiliPlus · Thread Ripper fork

[中文](README.md) | English

This is a fork of [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus). This page covers the differences; see the [upstream README](https://github.com/bggRGjQaUbCoE/PiliPlus#readme) for the original features and project information.

## Changes from upstream

- Integrates [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) download scheduling into the shared player on Android, iOS, Windows, macOS, and Linux.
- Shares the request limit between video and audio, with automatic tuning or 4, 8, 16, or 32 requests and mainland, overseas, or custom official CDN hosts.
- Sends a small initial block and delivers later chunks promptly in byte order to reduce initial buffering. Slow startup nodes get a backup after 200 ms.
- Adds separately enabled experimental HLS live acceleration, segment prefetching, and throughput, concurrency, retry, and fallback statistics.
- Uses a persistent Android signing key for this fork. In-app update checks and downloads point to this repository.

Acceleration is off by default. Open **Settings → Audio/Video settings → 线程撕裂者 · 多线程加速**, or use the video settings panel or live player menu. Saving settings in the player preserves the playback position and paused state.

## Downloads

Get this fork's packages from [Releases](https://github.com/alvinmhng/PiliPlus/releases/latest). Android packages cover `arm64-v8a`, `armeabi-v7a`, and `x86_64`; other platforms retain upstream's packaging.

Older APKs signed with temporary runner keys, and APKs signed by upstream, cannot be upgraded directly to the persistent fork key. Back up settings, uninstall the old APK, and install this fork once; subsequent fork releases can update normally.

## Maintenance and credits

- [Acceleration details](docs/thread-ripper.md)
- [Persistent signing and manual builds](docs/fork-maintenance.md)
- Retains upstream's [GPL-3.0 license](LICENSE). Thread Ripper's MIT license is bundled with the app.
- Thanks to [upstream PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) and [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper).
