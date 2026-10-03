import 'package:PiliPlus/common/widgets/active_tab_ticker.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Probe {
  int ticks = 0;
  int creations = 0;
  int disposals = 0;
}

class _TickerProbe extends StatefulWidget {
  const _TickerProbe(this.probe, {super.key});

  final _Probe probe;

  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.probe.creations++;
    _ticker = createTicker((_) => widget.probe.ticks++)..start();
  }

  @override
  void dispose() {
    widget.probe.disposals++;
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const SizedBox(height: 100);
  }
}

class _ObservedAnimation extends Animation<double> {
  _ObservedAnimation(this.delegate);

  final Animation<double> delegate;
  final Set<VoidCallback> listeners = {};

  @override
  double get value => delegate.value;

  @override
  AnimationStatus get status => delegate.status;

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    delegate.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    delegate.removeListener(listener);
  }

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      delegate.addStatusListener(listener);

  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      delegate.removeStatusListener(listener);
}

class _ObservedTabController extends TabController {
  _ObservedTabController({required super.length, required super.vsync});

  late final _ObservedAnimation observedAnimation = _ObservedAnimation(
    super.animation!,
  );

  bool get hasObservers => hasListeners;

  @override
  Animation<double>? get animation =>
      super.animation == null ? null : observedAnimation;
}

class _NoAnimationTabController extends TabController {
  _NoAnimationTabController({required super.length, required super.vsync});

  @override
  Animation<double>? get animation => null;
}

class _ObservedPageController extends PageController {
  _ObservedPageController({super.initialPage});

  bool get hasObservers => hasListeners;
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: child),
);

List<Widget> _probeChildren(List<_Probe> probes) => [
  for (var index = 0; index < probes.length; index++)
    _TickerProbe(probes[index], key: ValueKey(index)),
];

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _tabEnabled(WidgetTester tester, int index) => tester
    .widget<TickerMode>(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is ActiveTabTickerMode && widget.index == index,
          skipOffstage: false,
        ),
        matching: find.byType(TickerMode, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .enabled;

bool _pageEnabled(WidgetTester tester, int index) => tester
    .widget<TickerMode>(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is ActivePageTickerMode && widget.index == index,
          skipOffstage: false,
        ),
        matching: find.byType(TickerMode, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .enabled;

void main() {
  testWidgets('retained tabs stop ticking and resume without losing state', (
    tester,
  ) async {
    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    final probes = List.generate(2, (_) => _Probe());
    await tester.pumpWidget(
      _app(
        TabBarView(
          controller: controller,
          children: activeTabChildren(
            _probeChildren(probes),
            controller: controller,
          ),
        ),
      ),
    );
    await _frames(tester);
    expect(probes[0].ticks, greaterThan(0));
    controller.index = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final hiddenTicks = probes[0].ticks;
    final visibleTicks = probes[1].ticks;
    await _frames(tester);
    expect(probes[0].ticks, hiddenTicks);
    expect(probes[1].ticks, greaterThan(visibleTicks));
    expect(probes[0].disposals, 0);
    controller.index = 0;
    await tester.pump();
    await _frames(tester);
    expect(probes[0].ticks, greaterThan(hiddenTicks));
    expect(probes[0].creations, 1);
    expect(probes[1].creations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retained pages stop ticking and resume without losing state', (
    tester,
  ) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final probes = List.generate(2, (_) => _Probe());
    await tester.pumpWidget(
      _app(
        PageView(
          controller: controller,
          children: activePageChildren(
            _probeChildren(probes),
            controller: controller,
          ),
        ),
      ),
    );
    await _frames(tester);
    controller.jumpToPage(1);
    await tester.pump();
    final hiddenTicks = probes[0].ticks;
    final visibleTicks = probes[1].ticks;
    await _frames(tester);
    expect(probes[0].ticks, hiddenTicks);
    expect(probes[1].ticks, greaterThan(visibleTicks));
    expect(probes[0].disposals, 0);
    controller.jumpToPage(0);
    await tester.pump();
    await _frames(tester);
    expect(probes[0].ticks, greaterThan(hiddenTicks));
    expect(probes[0].creations, 1);
    expect(probes[1].creations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interactive tab swipe enables both partially visible pages', (
    tester,
  ) async {
    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);
    final probes = List.generate(3, (_) => _Probe());
    await tester.pumpWidget(
      _app(
        TabBarView(
          controller: controller,
          children: activeTabChildren(
            _probeChildren(probes),
            controller: controller,
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(500, 300));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(controller.animation!.value, greaterThan(0));
    expect(controller.animation!.value, lessThan(1));
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 1), isTrue);
    await gesture.up();
    // The first frame starts the ballistic simulation. Pump bounded frames
    // because the visible probe's repeating ticker prevents pumpAndSettle.
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final selected = controller.index;
    expect(controller.animation!.value, selected.toDouble());
    expect(controller.offset, 0);
    expect(_tabEnabled(tester, selected), isTrue);
    expect(_tabEnabled(tester, 1 - selected), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tab offsets notify visibility without an index change', (
    tester,
  ) async {
    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: activeTabChildren(
            _probeChildren(List.generate(3, (_) => _Probe())),
            controller: controller,
          ),
        ),
      ),
    );
    controller.offset = 0.25;
    await tester.pump();
    expect(controller.index, 0);
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 1), isTrue);
    expect(_tabEnabled(tester, 2), isFalse);
    controller.offset = 0;
    await tester.pump();
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 1), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('nonadjacent tab jumps keep only outgoing and target active', (
    tester,
  ) async {
    final controller = TabController(length: 4, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: activeTabChildren(
            _probeChildren(List.generate(4, (_) => _Probe())),
            controller: controller,
          ),
        ),
      ),
    );
    controller.animateTo(3, duration: const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.indexIsChanging, isTrue);
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 3), isTrue);
    expect(_tabEnabled(tester, 1), isFalse);
    expect(_tabEnabled(tester, 2), isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.indexIsChanging, isFalse);
    expect(_tabEnabled(tester, 0), isFalse);
    expect(_tabEnabled(tester, 3), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('page transitions keep both intersecting pages active', (
    tester,
  ) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        PageView(
          controller: controller,
          children: activePageChildren(
            _probeChildren(List.generate(3, (_) => _Probe())),
            controller: controller,
          ),
        ),
      ),
    );
    final movement = controller.animateToPage(
      1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.linear,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.page, closeTo(0.5, 0.01));
    expect(_pageEnabled(tester, 0), isTrue);
    expect(_pageEnabled(tester, 1), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    await movement;
    expect(_pageEnabled(tester, 0), isFalse);
    expect(_pageEnabled(tester, 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('GlobalKeys preserve tab state across a distant animated warp', (
    tester,
  ) async {
    final controller = TabController(length: 4, vsync: tester);
    addTearDown(controller.dispose);
    final probes = List.generate(4, (_) => _Probe());
    final keys = List.generate(4, (_) => GlobalKey<_TickerProbeState>());
    await tester.pumpWidget(
      _app(
        TabBarView(
          controller: controller,
          children: activeTabChildren(
            [
              for (var index = 0; index < probes.length; index++)
                _TickerProbe(probes[index], key: keys[index]),
            ],
            controller: controller,
          ),
        ),
      ),
    );
    await _frames(tester);
    final firstState = keys[0].currentState;
    controller.animateTo(3, duration: const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.indexIsChanging, isTrue);
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 3), isTrue);
    expect(keys[0].currentState, same(firstState));
    expect(keys[3].currentState, isNotNull);
    await tester.pump(const Duration(milliseconds: 500));
    final hiddenTicks = probes[0].ticks;
    final targetTicks = probes[3].ticks;
    await _frames(tester);
    expect(probes[0].ticks, hiddenTicks);
    expect(probes[3].ticks, greaterThan(targetTicks));
    expect(probes[0].creations, 1);
    controller.animateTo(0, duration: const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(keys[0].currentState, same(firstState));
    expect(probes[0].creations, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fractional page viewport keeps every visible page active', (
    tester,
  ) async {
    final controller = PageController(initialPage: 1, viewportFraction: 0.5);
    addTearDown(controller.dispose);
    final probes = List.generate(5, (_) => _Probe());
    await tester.pumpWidget(
      _app(
        PageView(
          controller: controller,
          children: activePageChildren(
            _probeChildren(probes),
            controller: controller,
          ),
        ),
      ),
    );
    await _frames(tester);
    for (final index in [0, 1, 2]) {
      expect(_pageEnabled(tester, index), isTrue);
      expect(probes[index].ticks, greaterThan(0));
    }
    controller.jumpToPage(3);
    await tester.pump();
    final oldTicks = probes[0].ticks;
    await _frames(tester);
    expect(probes[0].ticks, oldTicks);
    expect(_pageEnabled(tester, 0), isFalse);
    for (final index in [2, 3, 4]) {
      expect(_pageEnabled(tester, index), isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('outer TickerMode dominates nested active tab visibility', (
    tester,
  ) async {
    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    final probes = List.generate(2, (_) => _Probe());
    final child = Column(
      children: activeTabChildren(
        _probeChildren(probes),
        controller: controller,
      ),
    );
    await tester.pumpWidget(
      _app(TickerMode(enabled: false, child: child)),
    );
    await _frames(tester);
    controller.index = 1;
    await tester.pump();
    await _frames(tester);
    expect(probes.map((probe) => probe.ticks), everyElement(0));
    await tester.pumpWidget(
      _app(TickerMode(enabled: true, child: child)),
    );
    await _frames(tester);
    expect(probes[0].ticks, 0);
    expect(probes[1].ticks, greaterThan(0));
    expect(probes.map((probe) => probe.creations), everyElement(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('inherited DefaultTabController updates and can be replaced', (
    tester,
  ) async {
    late TabController inherited;
    final probes = List.generate(3, (_) => _Probe());
    Widget build(int length) => _app(
      DefaultTabController(
        length: length,
        initialIndex: 1,
        child: Builder(
          builder: (context) {
            inherited = DefaultTabController.of(context);
            return Column(
              children: activeTabChildren(
                _probeChildren(probes.take(length).toList()),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(build(2));
    expect(_tabEnabled(tester, 0), isFalse);
    expect(_tabEnabled(tester, 1), isTrue);
    inherited.index = 0;
    await tester.pump();
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 1), isFalse);
    final previous = inherited;
    await tester.pumpWidget(build(3));
    expect(inherited, isNot(same(previous)));
    inherited.index = 2;
    await tester.pump();
    expect(_tabEnabled(tester, 0), isFalse);
    expect(_tabEnabled(tester, 2), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tab controller replacement and disposal remove all listeners', (
    tester,
  ) async {
    final first = _ObservedTabController(length: 2, vsync: tester);
    final second = _ObservedTabController(length: 2, vsync: tester);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final probes = List.generate(2, (_) => _Probe());
    Widget build(TabController controller) => _app(
      Column(
        children: activeTabChildren(
          _probeChildren(probes),
          controller: controller,
        ),
      ),
    );
    await tester.pumpWidget(build(first));
    expect(first.hasObservers, isTrue);
    expect(first.observedAnimation.listeners, hasLength(2));
    second.index = 1;
    await tester.pumpWidget(build(second));
    expect(first.hasObservers, isFalse);
    expect(first.observedAnimation.listeners, isEmpty);
    expect(second.observedAnimation.listeners, hasLength(2));
    expect(_tabEnabled(tester, 0), isFalse);
    expect(_tabEnabled(tester, 1), isTrue);
    first
      ..index = 1
      ..offset = -0.5;
    await tester.pump();
    expect(_tabEnabled(tester, 0), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.hasObservers, isFalse);
    expect(second.observedAnimation.listeners, isEmpty);
    second.offset = -0.25;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('page controller replacement and disposal remove listeners', (
    tester,
  ) async {
    final first = _ObservedPageController();
    final second = _ObservedPageController(initialPage: 1);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final probes = List.generate(2, (_) => _Probe());
    Widget build(PageController controller) => _app(
      Column(
        children: activePageChildren(
          _probeChildren(probes),
          controller: controller,
        ),
      ),
    );
    await tester.pumpWidget(build(first));
    expect(first.hasObservers, isTrue);
    expect(_pageEnabled(tester, 0), isTrue);
    await tester.pumpWidget(build(second));
    expect(first.hasObservers, isFalse);
    expect(second.hasObservers, isTrue);
    expect(_pageEnabled(tester, 0), isFalse);
    expect(_pageEnabled(tester, 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.hasObservers, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabs without animation fall back to selected index', (
    tester,
  ) async {
    final controller = _NoAnimationTabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: activeTabChildren(
            _probeChildren(List.generate(2, (_) => _Probe())),
            controller: controller,
          ),
        ),
      ),
    );
    expect(_tabEnabled(tester, 0), isTrue);
    expect(_tabEnabled(tester, 1), isFalse);
    controller.index = 1;
    await tester.pump();
    expect(_tabEnabled(tester, 0), isFalse);
    expect(_tabEnabled(tester, 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final pages in [false, true]) {
    testWidgets('keyed children preserve state when reordered, pages=$pages', (
      tester,
    ) async {
      final tabController = TabController(length: 2, vsync: tester);
      final pageController = PageController();
      addTearDown(tabController.dispose);
      addTearDown(pageController.dispose);
      final first = _Probe();
      final second = _Probe();
      final firstKey = GlobalKey<_TickerProbeState>();
      const secondKey = ValueKey('second');
      final children = <Widget>[
        _TickerProbe(first, key: firstKey),
        _TickerProbe(second, key: secondKey),
      ];
      Widget build(List<Widget> children) => _app(
        Column(
          children: pages
              ? activePageChildren(children, controller: pageController)
              : activeTabChildren(children, controller: tabController),
        ),
      );
      await tester.pumpWidget(build(children));
      final firstState = firstKey.currentState;
      final secondState = tester.state(find.byKey(secondKey));
      await tester.pumpWidget(build(children.reversed.toList()));
      expect(firstKey.currentState, same(firstState));
      expect(tester.state(find.byKey(secondKey)), same(secondState));
      expect(first.creations, 1);
      expect(second.creations, 1);
      expect(first.disposals, 0);
      expect(second.disposals, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('PageStorage-restored position controls initial visibility', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    final first = PageController();
    final second = PageController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final probes = List.generate(3, (_) => _Probe());
    Widget build(PageController controller) => _app(
      PageStorage(
        bucket: bucket,
        child: PageView(
          key: const PageStorageKey('restored-pages'),
          controller: controller,
          children: activePageChildren(
            _probeChildren(probes),
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpWidget(build(first));
    first.jumpToPage(2);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(build(second));
    await tester.pump();
    expect(second.page, 2);
    expect(_pageEnabled(tester, 2), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
