import 'dart:async';

import 'package:PiliPlus/common/widgets/flutter/live_list_view.dart';
import 'package:PiliPlus/pages/live_room/live_work.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'repeated chat starts share one token request and one connection',
    () async {
      final startup = LiveMessageStartup<String>();
      final token = Completer<String>();
      int requests = 0;
      int connections = 0;
      Future<void> start() => startup.start(
        load: () {
          requests++;
          return token.future;
        },
        connected: () => connections != 0,
        connect: (_) => connections++,
      );

      final first = start();
      await start();
      expect(requests, 1);
      token.complete('token');
      await first;
      await start();
      expect(requests, 1);
      expect(connections, 1);
    },
  );

  test(
    'stopping chat prevents a delayed token from opening a socket',
    () async {
      final startup = LiveMessageStartup<String>();
      final token = Completer<String>();
      int connections = 0;
      final pending = startup.start(
        load: () => token.future,
        connected: () => false,
        connect: (_) => connections++,
      );
      startup.stop();
      token.complete('old-token');
      await pending;
      expect(connections, 0);
      expect(startup.wanted, isFalse);
    },
  );

  test(
    'a stale completion cannot replace or unlock a new chat startup',
    () async {
      final startup = LiveMessageStartup<String>();
      final oldToken = Completer<String>();
      final newToken = Completer<String>();
      final connections = <String>[];
      int requests = 0;
      Future<void> start(Completer<String> token) => startup.start(
        load: () {
          requests++;
          return token.future;
        },
        connected: () => connections.isNotEmpty,
        connect: connections.add,
      );

      final old = start(oldToken);
      startup.stop();
      final replacement = start(newToken);
      oldToken.complete('old-token');
      await old;
      await start(newToken);
      expect(requests, 2);
      expect(connections, isEmpty);
      newToken.complete('new-token');
      await replacement;
      expect(connections, ['new-token']);
    },
  );

  test(
    'disposal rejects late completions and further startup requests',
    () async {
      final startup = LiveMessageStartup<String>();
      final token = Completer<String>();
      int requests = 0;
      int connections = 0;
      Future<void> start() => startup.start(
        load: () {
          requests++;
          return token.future;
        },
        connected: () => false,
        connect: (_) => connections++,
      );

      final pending = start();
      startup.dispose();
      token.complete('token');
      await pending;
      await start();
      expect(requests, 1);
      expect(connections, 0);
    },
  );

  test(
    'hidden busy chat defers updates without discarding retained rows',
    () {
      final messages = <dynamic>[];
      final history = LiveChatHistory(
        retain: 500,
        overflow: 50,
        safeMargin: 200,
      );
      int notifications = 0;
      final updates = DeferredLiveUpdates(() => notifications++);
      for (int index = 0; index < 10000; index++) {
        messages.add(index);
        history.trim(messages, renderedIndex: 19);
        updates.changed();
      }
      expect(notifications, 0);
      expect(messages.length, 10000); // Stable indices are intentional.
      expect(history.trimmed, 0);
      expect(messages.where((item) => item != null).length, 10000);
      expect(
        messages.sublist(9500),
        List.generate(500, (index) => 9500 + index),
      );
      updates.visible = true;
      expect(updates.refresh(), isTrue);
      expect(notifications, 1);
      expect(updates.refresh(), isFalse);
      expect(notifications, 1);
    },
  );

  test('history trimming releases only safely passed rows', () {
    final messages = List<dynamic>.generate(1000, (index) => index);
    final history = LiveChatHistory(retain: 500, overflow: 50, safeMargin: 200)
      ..trim(messages, renderedIndex: 700);
    expect(history.trimmed, 0);
    history.trim(messages, renderedIndex: 701);
    expect(history.trimmed, 500);
    expect(messages.take(500), everyElement(isNull));
    expect(messages.sublist(500), List.generate(500, (index) => index + 500));
  });

  testWidgets('hidden retained chat reveals its original rows without holes', (
    tester,
  ) async {
    final messages = List<dynamic>.generate(20, (index) => index);
    final history = LiveChatHistory(retain: 500, overflow: 50, safeMargin: 200);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    late StateSetter update;
    bool hidden = false;
    int renderedIndex = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Offstage(
              offstage: hidden,
              child: SizedBox(
                height: 300,
                child: LiveListView.separated(
                  controller: scrollController,
                  initialIndex: history.trimmed * 2,
                  itemCount: messages.length,
                  itemBuilder: (_, index) {
                    renderedIndex = index;
                    return messages[index] == null
                        ? null
                        : SizedBox(
                            height: 30,
                            child: Text('message ${messages[index]}'),
                          );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                ),
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('message 0'), findsOneWidget);
    final initialOffset = scrollController.offset;
    update(() => hidden = true);
    await tester.pump();
    for (int index = 20; index < 1000; index++) {
      messages.add(index);
      history.trim(messages, renderedIndex: renderedIndex);
    }
    expect(history.trimmed, 0);
    update(() => hidden = false);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('message 0'), findsOneWidget);
    expect(scrollController.offset, initialOffset);
  });

  test(
    'visible updates notify normally while scrolling can defer new rows',
    () {
      int notifications = 0;
      final updates = DeferredLiveUpdates(() => notifications++)
        ..visible = true
        ..changed();
      expect(notifications, 1);
      updates
        ..changed(notify: false)
        ..changed(notify: false);
      expect(notifications, 1);
      updates.refresh();
      expect(notifications, 2);
    },
  );

  test(
    'a hidden SuperChat panel preserves entries and refreshes on reveal',
    () {
      final items = <String>[];
      int notifications = 0;
      final updates = DeferredLiveUpdates(() => notifications++);
      items.insert(0, 'paid message');
      updates.changed();
      expect(items, ['paid message']);
      expect(notifications, 0);
      updates
        ..visible = true
        ..refresh();
      expect(notifications, 1);
    },
  );
}
