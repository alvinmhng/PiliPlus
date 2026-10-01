import 'dart:io';

import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/pages/setting/widgets/thread_ripper_dialog.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('piliplus-ripper-settings-');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  setUp(() => GStorage.setting.clear());
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showThreadRipperDialog(context),
                child: const Text('打开加速设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开加速设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('settings fit a phone and persist opt-in controls after saving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester);
    expect(Pref.threadRipper.enabled, isFalse);
    await tester.tap(find.text('开启多线程加速'));
    await tester.tap(find.text('直播加速（实验）'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(ThreadRipperSettingsDialog), findsNothing);
    expect(Pref.threadRipper.enabled, isTrue);
    expect(Pref.threadRipper.liveEnabled, isTrue);
    expect(Pref.threadRipper.automatic, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('打开加速设置'));
    await tester.pumpAndSettle();
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches.map((item) => item.value), everyElement(isTrue));
  });

  testWidgets(
    'cancel discards changes and short landscape layouts do not overflow',
    (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester);
      await tester.tap(find.text('开启多线程加速'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(Pref.threadRipper.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test('stored malformed or old preferences use safe defaults', () async {
    await GStorage.setting.put(SettingBoxKey.threadRipper, {
      'enabled': true,
      'mode': 'unknown',
      'concurrency': 128,
      'customHosts': ['attacker.example', 42],
    });
    final options = Pref.threadRipper;
    expect(options.enabled, isTrue);
    expect(options.mode, ThreadRipperCdnMode.mainland);
    expect(options.automatic, isTrue);
    expect(options.customHosts, isEmpty);
    expect(options.liveEnabled, isFalse);
  });
}
