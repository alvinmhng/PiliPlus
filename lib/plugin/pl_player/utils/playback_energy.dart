import 'dart:async';

bool canRenderDanmaku({
  required bool enabled,
  required double opacity,
  required bool visible,
  required bool showDanmaku,
  required bool playing,
  required bool audioOnly,
  bool inPip = false,
  bool requirePlaying = true,
}) =>
    enabled &&
    opacity > 0 &&
    !audioOnly &&
    (inPip || (visible && showDanmaku)) &&
    (!requirePlaying || playing);

bool canSuspendBackgroundVideo({
  required bool mobile,
  required bool backgrounded,
  required bool backgroundPlay,
  required bool inPip,
  required bool android,
  bool ios = false,
  required bool autoPip,
  required bool manualPipPending,
}) =>
    mobile &&
    backgrounded &&
    backgroundPlay &&
    !inPip &&
    !((android || ios) && (autoPip || manualPipPending));

bool hasSelectedPlaybackAudio({
  required String track,
  required int? sampleRate,
}) =>
    track.isNotEmpty &&
    track != 'no' &&
    track != 'auto' &&
    (sampleRate ?? 0) > 0;

({String track, bool suspended, String restore}) videoTrackForReload({
  required String current,
  required String? restoration,
  required bool backgrounded,
  required bool audioOnly,
}) {
  final previous = restoration ?? current;
  final selected = previous.isEmpty ? 'auto' : previous;
  return (
    track: backgrounded || audioOnly ? 'no' : selected,
    suspended: backgrounded && !audioOnly && selected != 'no',
    restore: selected,
  );
}

/// Buffer changes cannot postpone releasing a paused player's screen wake lock.
class PlaybackWakeLockRelease {
  PlaybackWakeLockRelease(this.release);
  final void Function() release;
  Timer? _timer;

  void schedule() {
    cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _timer = null;
      release();
    });
  }

  void buffering({required bool playing}) {
    if (playing) cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Temporarily deselects video without changing the user's track preference.
/// A new source starts a separate restoration scope.
class BackgroundVideoTrack {
  int? _generation;
  String? _restore;
  String? get restoration => _restore;

  void reset() {
    _generation = null;
    _restore = null;
  }

  void sourceReady(
    int generation, {
    required bool openedSuspended,
    String suspendedTrack = 'auto',
  }) {
    _generation = generation;
    // A newly opened media uses automatic track selection unless audio-only.
    _restore = openedSuspended ? suspendedTrack : null;
  }

  void update({
    required int generation,
    required bool suspended,
    required bool audioOnly,
    required String Function() read,
    required void Function(String) write,
  }) {
    if (_generation != generation) return;
    final current = read();
    if (audioOnly) {
      _restore = null;
      return;
    }
    if (suspended) {
      if (current.isEmpty || current == 'no') return;
      _restore ??= current;
      write('no');
    } else if (_restore case final original?) {
      // A loadfile command can return before track discovery. Keep the pending
      // restoration until track-list updates expose the new file's selection.
      if (current.isEmpty || current == 'auto') return;
      // Respect a track the user selected while the override was active.
      _restore = null;
      if (current == 'no') write(original);
    }
  }
}
