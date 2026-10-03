import 'package:PiliPlus/common/skeleton/video_reply.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('muting a measurement skeleton preserves every item extent', (
    tester,
  ) async {
    const itemKey = ValueKey('first item');
    const listKey = ValueKey('prototype list');

    Widget build({required bool muted}) => MaterialApp(
      home: CustomScrollView(
        slivers: [
          SliverPrototypeExtentList(
            key: listKey,
            prototypeItem: TickerMode(
              enabled: !muted,
              child: const VideoReplySkeleton(),
            ),
            delegate: SliverChildListDelegate(const [
              SizedBox(key: itemKey),
              SizedBox(),
              SizedBox(),
            ]),
          ),
        ],
      ),
    );

    await tester.pumpWidget(build(muted: false));
    await tester.pump(const Duration(milliseconds: 50));
    final extent = tester
        .renderObject<RenderSliver>(find.byKey(listKey))
        .geometry!
        .scrollExtent;
    final itemHeight = tester.getSize(find.byKey(itemKey)).height;
    expect(itemHeight, greaterThan(0));
    expect(extent, closeTo(itemHeight * 3, 0.001));
    expect(tester.binding.transientCallbackCount, 1);

    await tester.pumpWidget(build(muted: true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getSize(find.byKey(itemKey)).height, itemHeight);
    expect(
      tester
          .renderObject<RenderSliver>(find.byKey(listKey))
          .geometry!
          .scrollExtent,
      extent,
    );
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'visible loading skeleton still animates with a muted prototype',
    (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomScrollView(
            slivers: [
              SliverPrototypeExtentList(
                prototypeItem: const TickerMode(
                  enabled: false,
                  child: VideoReplySkeleton(),
                ),
                delegate: SliverChildListDelegate(const [VideoReplySkeleton()]),
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
