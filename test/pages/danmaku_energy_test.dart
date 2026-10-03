import 'package:PiliPlus/plugin/pl_player/widgets/energy_aware_danmaku.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late DanmakuController<Object> controller;
  late StateSetter update;
  late bool enabled;
  late bool playing;
  late double opacity;
  late Size size;
  late DanmakuOption option;

  setUp(() {
    enabled = true;
    playing = true;
    opacity = 1;
    size = const Size(320, 160);
    option = const DanmakuOption(duration: 1);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: SizedBox.fromSize(
                size: size,
                child: EnergyAwareDanmaku<Object>(
                  enabled: enabled,
                  playing: playing,
                  opacity: opacity,
                  option: option,
                  size: size,
                  createdController: (value) => controller = value,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  int getItemCount() => controller.scrollDanmaku.fold(
    0,
    (count, track) => count + track.length,
  );

  Future<void> settleVisibility(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
  }

  testWidgets('zero opacity rejects new comments and stops all canvas frames', (
    tester,
  ) async {
    opacity = 0;
    await open(tester);
    controller.resume();
    expect(controller.running, isFalse);
    for (var frame = 0; frame < 180; frame++) {
      expect(
        controller.addDanmaku(DanmakuContentItem<Object>('hidden $frame')),
        isFalse,
      );
      await tester.pump(const Duration(milliseconds: 17));
    }
    expect(getItemCount(), 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('hiding clears existing comments and re-enabling playing works', (
    tester,
  ) async {
    await open(tester);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('before hiding')),
      isTrue,
    );
    await tester.pump();
    expect(getItemCount(), 1);
    update(() => enabled = false);
    await settleVisibility(tester);
    expect(getItemCount(), 0);
    expect(controller.running, isFalse);
    controller.resume();
    expect(controller.running, isFalse);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('hidden')),
      isFalse,
    );
    expect(tester.binding.transientCallbackCount, 0);

    update(() => enabled = true);
    await settleVisibility(tester);
    expect(controller.running, isTrue);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('after re-enabling')),
      isTrue,
    );
    await tester.pump();
    expect(getItemCount(), 1);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('setting opacity to zero clears a canvas already playing', (
    tester,
  ) async {
    await open(tester);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('before opacity zero')),
      isTrue,
    );
    await tester.pump();
    expect(getItemCount(), 1);
    update(() => opacity = 0);
    await settleVisibility(tester);
    expect(controller.running, isFalse);
    expect(getItemCount(), 0);
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('invisible')),
      isFalse,
    );
    update(() => opacity = 1);
    await settleVisibility(tester);
    expect(controller.running, isTrue);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('visible again')),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'visible pause freezes comments and rejects resume until playing',
    (
      tester,
    ) async {
      await open(tester);
      expect(
        controller.addDanmaku(DanmakuContentItem<Object>('frozen')),
        isTrue,
      );
      await tester.pump();
      update(() => playing = false);
      await tester.pump();
      final item = controller.scrollDanmaku.expand((track) => track).single;
      final pausedPosition = item.xPosition;
      controller.resume();
      await tester.pump(const Duration(seconds: 3));
      expect(controller.running, isFalse);
      expect(getItemCount(), 1);
      expect(item.xPosition, pausedPosition);
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        controller.addDanmaku(DanmakuContentItem<Object>('while paused')),
        isFalse,
      );
      update(() => playing = true);
      await tester.pump();
      expect(controller.running, isTrue);
      expect(getItemCount(), 1);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('restoring opacity while paused remains idle until play', (
    tester,
  ) async {
    opacity = 0;
    playing = false;
    await open(tester);
    update(() => opacity = 1);
    await settleVisibility(tester);
    controller.resume();
    expect(controller.running, isFalse);
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('still paused')),
      isFalse,
    );
    expect(tester.binding.transientCallbackCount, 0);
    update(() => playing = true);
    await tester.pump();
    expect(
      controller.addDanmaku(DanmakuContentItem<Object>('playing again')),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'size/options updates and seek clear preserve the guarded owner',
    (
      tester,
    ) async {
      await open(tester);
      final initialController = controller;
      expect(
        controller.addDanmaku(DanmakuContentItem<Object>('before fullscreen')),
        isTrue,
      );
      await tester.pump();
      update(() {
        size = const Size(640, 320);
        option = const DanmakuOption(fontSize: 24, duration: 2);
      });
      await tester.pump();
      expect(controller, same(initialController));
      expect(controller.option.fontSize, 24);
      expect(controller.option.duration, 2);
      controller.clear();
      expect(getItemCount(), 0);
      expect(
        controller.addDanmaku(DanmakuContentItem<Object>('after seeking')),
        isTrue,
      );
      await tester.pump();
      expect(getItemCount(), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        initialController.addDanmaku(DanmakuContentItem<Object>('disposed')),
        isFalse,
      );
    },
  );
}
