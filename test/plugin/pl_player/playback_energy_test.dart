import 'package:PiliPlus/plugin/pl_player/utils/playback_energy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('buffer changes retain the original paused wake-lock deadline', (
    tester,
  ) async {
    var releases = 0;
    final release = PlaybackWakeLockRelease(() => releases++)..schedule();
    await tester.pump(const Duration(milliseconds: 250));
    release.buffering(playing: false);
    await tester.pump(const Duration(milliseconds: 249));
    expect(releases, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(releases, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(releases, 1);
  });

  testWidgets('resume and disposal cancel a pending wake-lock release', (
    tester,
  ) async {
    var releases = 0;
    final release = PlaybackWakeLockRelease(() => releases++)..schedule();
    await tester.pump(const Duration(milliseconds: 250));
    release.buffering(playing: true);
    await tester.pump(const Duration(seconds: 1));
    expect(releases, 0);
    release
      ..schedule()
      ..cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(releases, 0);
  });

  test(
    'danmaku remains eligible in PiP but respects opacity and audio-only',
    () {
      bool allowed({
        bool enabled = true,
        double opacity = 1,
        bool playing = true,
        bool audioOnly = false,
        bool inPip = true,
        bool requirePlaying = true,
      }) => canRenderDanmaku(
        enabled: enabled,
        opacity: opacity,
        visible: false,
        showDanmaku: false,
        playing: playing,
        audioOnly: audioOnly,
        inPip: inPip,
        requirePlaying: requirePlaying,
      );
      expect(allowed(), isTrue);
      expect(allowed(inPip: false), isFalse);
      expect(allowed(enabled: false), isFalse);
      expect(allowed(opacity: 0), isFalse);
      expect(allowed(audioOnly: true), isFalse);
      expect(allowed(playing: false), isFalse);
      expect(allowed(playing: false, requirePlaying: false), isTrue);
    },
  );

  test(
    'background video preserves pending and active Android PiP transitions',
    () {
      bool suspend({
        bool mobile = true,
        bool backgrounded = true,
        bool backgroundPlay = true,
        bool inPip = false,
        bool android = true,
        bool autoPip = false,
        bool manualPipPending = false,
      }) => canSuspendBackgroundVideo(
        mobile: mobile,
        backgrounded: backgrounded,
        backgroundPlay: backgroundPlay,
        inPip: inPip,
        android: android,
        autoPip: autoPip,
        manualPipPending: manualPipPending,
      );
      expect(suspend(), isTrue);
      expect(suspend(mobile: false), isFalse);
      expect(suspend(backgrounded: false), isFalse);
      expect(suspend(backgroundPlay: false), isFalse);
      expect(suspend(inPip: true), isFalse);
      expect(suspend(autoPip: true), isFalse);
      expect(suspend(manualPipPending: true), isFalse);
      expect(suspend(android: false, autoPip: true), isTrue);
    },
  );

  test('background video restores its exact selected track', () {
    var current = '2';
    final writes = <String>[];
    final policy = BackgroundVideoTrack()
      ..sourceReady(1, openedSuspended: false);
    void update(bool suspended) => policy.update(
      generation: 1,
      suspended: suspended,
      audioOnly: false,
      read: () => current,
      write: (value) {
        writes.add(value);
        current = value;
      },
    );
    update(true);
    update(true);
    expect(writes, ['no']);
    update(false);
    update(false);
    expect(writes, ['no', '2']);
  });

  test('video-only and undiscovered audio cannot enable video suspension', () {
    expect(hasSelectedPlaybackAudio(track: 'no', sampleRate: null), isFalse);
    expect(hasSelectedPlaybackAudio(track: '', sampleRate: 48000), isFalse);
    expect(hasSelectedPlaybackAudio(track: 'auto', sampleRate: 48000), isFalse);
    expect(hasSelectedPlaybackAudio(track: '1', sampleRate: null), isFalse);
    expect(hasSelectedPlaybackAudio(track: '1', sampleRate: 0), isFalse);
    expect(hasSelectedPlaybackAudio(track: '1', sampleRate: 48000), isTrue);
  });

  test(
    'foreground reopen replaces a copied background option with selected vid',
    () {
      final oldOptions = {'vid': 'no', 'cache': 'yes', 'af': 'volume=1'};
      final selection = videoTrackForReload(
        current: '2',
        restoration: null,
        backgrounded: false,
        audioOnly: false,
      );
      final copied = {...oldOptions, 'vid': selection.track};
      expect(copied, {'vid': '2', 'cache': 'yes', 'af': 'volume=1'});
      expect(oldOptions['vid'], 'no');
      expect(selection.suspended, isFalse);
      expect(
        videoTrackForReload(
          current: '',
          restoration: null,
          backgrounded: false,
          audioOnly: false,
        ).track,
        'auto',
      );
    },
  );

  test('background reopen and audio-only keep their original video intent', () {
    final suspended = videoTrackForReload(
      current: 'no',
      restoration: '2',
      backgrounded: true,
      audioOnly: false,
    );
    expect(suspended, (track: 'no', suspended: true, restore: '2'));
    final current = videoTrackForReload(
      current: 'no',
      restoration: '2',
      backgrounded: false,
      audioOnly: false,
    );
    expect(current.track, '2');
    final audio = videoTrackForReload(
      current: 'no',
      restoration: '2',
      backgrounded: false,
      audioOnly: true,
    );
    expect(audio.track, 'no');
    expect(audio.suspended, isFalse);
  });

  test(
    'new background source restores its own default instead of an old track',
    () {
      var current = '2';
      final policy = BackgroundVideoTrack()
        ..sourceReady(1, openedSuspended: false);
      void update(int generation, bool suspended) => policy.update(
        generation: generation,
        suspended: suspended,
        audioOnly: false,
        read: () => current,
        write: (value) => current = value,
      );
      update(1, true);
      expect(current, 'no');
      policy.reset();
      current = '1';
      update(1, false);
      expect(current, '1');
      current = 'no'; // The new loadfile received a file-local vid=no option.
      policy.sourceReady(2, openedSuspended: true);
      update(1, false);
      expect(current, 'no');
      update(2, false);
      expect(current, 'auto');
    },
  );

  test(
    'restoration waits for discovery and respects a user-selected track',
    () {
      var current = '';
      final policy = BackgroundVideoTrack()
        ..sourceReady(1, openedSuspended: true);
      void update() => policy.update(
        generation: 1,
        suspended: false,
        audioOnly: false,
        read: () => current,
        write: (value) => current = value,
      );
      update();
      expect(current, '');
      current = 'auto';
      update();
      current = 'no';
      update();
      expect(current, 'auto');
      policy.sourceReady(1, openedSuspended: false);
      current = '2';
      policy.update(
        generation: 1,
        suspended: true,
        audioOnly: false,
        read: () => current,
        write: (value) => current = value,
      );
      current = '3';
      update();
      expect(current, '3');
    },
  );

  test('audio-only changes and an already disabled track remain disabled', () {
    var current = 'no';
    final policy = BackgroundVideoTrack()
      ..sourceReady(1, openedSuspended: false);
    void update({required bool suspended, bool audioOnly = false}) =>
        policy.update(
          generation: 1,
          suspended: suspended,
          audioOnly: audioOnly,
          read: () => current,
          write: (value) => current = value,
        );
    update(suspended: true);
    update(suspended: false);
    expect(current, 'no');
    current = '1';
    update(suspended: true);
    expect(current, 'no');
    update(suspended: false, audioOnly: true);
    update(suspended: false);
    expect(current, 'no');
  });
}
