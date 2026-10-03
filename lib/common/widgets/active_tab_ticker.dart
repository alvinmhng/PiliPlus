import 'package:material_ui/material_ui.dart';

List<Widget> activeTabChildren(
  List<Widget> children, {
  TabController? controller,
}) => List.generate(children.length, (index) {
  final child = children[index];
  return ActiveTabTickerMode(
    key: child.key == null ? null : ValueKey(child.key!),
    index: index,
    controller: controller,
    child: child,
  );
});

List<Widget> activePageChildren(
  List<Widget> children, {
  required PageController controller,
}) => List.generate(children.length, (index) {
  final child = children[index];
  return ActivePageTickerMode(
    key: child.key == null ? null : ValueKey(child.key!),
    index: index,
    controller: controller,
    child: child,
  );
});

/// Pauses animations in retained tabs while keeping their state and images.
class ActiveTabTickerMode extends StatefulWidget {
  const ActiveTabTickerMode({
    super.key,
    required this.index,
    this.controller,
    required this.child,
  }) : assert(index >= 0);

  final int index;
  final TabController? controller;
  final Widget child;

  @override
  State<ActiveTabTickerMode> createState() => _ActiveTabTickerModeState();
}

class _ActiveTabTickerModeState extends State<ActiveTabTickerMode> {
  TabController? _controller;
  Animation<double>? _animation;
  bool _enabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateController();
  }

  @override
  void didUpdateWidget(ActiveTabTickerMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateController();
  }

  void _updateController() {
    final controller =
        widget.controller ?? DefaultTabController.maybeOf(context);
    final animation = controller?.animation;
    if (_controller != controller || _animation != animation) {
      _removeListeners();
      _controller = controller;
      _animation = animation;
      _controller?.addListener(_updateVisibility);
      _animation?.addListener(_updateVisibility);
    }
    _enabled = _isVisible;
  }

  bool get _isVisible {
    final controller = _controller;
    if (controller == null) return true;
    // TabBarView moves the outgoing page beside the target for distant jumps.
    // Both remain visible even when their original indices are far apart.
    if (controller.indexIsChanging) {
      return widget.index == controller.index ||
          widget.index == controller.previousIndex;
    }
    final position = _animation?.value;
    if (position == null || !position.isFinite) {
      return widget.index == controller.index;
    }
    // During a swipe, both pages intersecting the viewport may animate.
    return (position - widget.index).abs() < 1;
  }

  void _updateVisibility() {
    final enabled = _isVisible;
    if (enabled != _enabled) {
      setState(() => _enabled = enabled);
    }
  }

  void _removeListeners() {
    _controller?.removeListener(_updateVisibility);
    _animation?.removeListener(_updateVisibility);
  }

  @override
  void dispose() {
    _removeListeners();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: _enabled, child: widget.child);
}

/// Pauses animations in retained pages outside a PageView's viewport.
class ActivePageTickerMode extends StatefulWidget {
  const ActivePageTickerMode({
    super.key,
    required this.index,
    required this.controller,
    required this.child,
  }) : assert(index >= 0);

  final int index;
  final PageController controller;
  final Widget child;

  @override
  State<ActivePageTickerMode> createState() => _ActivePageTickerModeState();
}

class _ActivePageTickerModeState extends State<ActivePageTickerMode> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateVisibility);
    _enabled = _isVisible;
    _updateAfterLayout();
  }

  @override
  void didUpdateWidget(ActivePageTickerMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateVisibility);
      widget.controller.addListener(_updateVisibility);
      _updateAfterLayout();
    }
    _enabled = _isVisible;
  }

  void _updateAfterLayout() {
    // PageStorage can restore a different page during the first layout without
    // a scroll notification. Read that position once dimensions are available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateVisibility();
    });
  }

  bool get _isVisible {
    final controller = widget.controller;
    if (controller.positions.length != 1) {
      return widget.index == controller.initialPage;
    }
    final scrollPosition = controller.position;
    if (!scrollPosition.hasPixels || !scrollPosition.hasContentDimensions) {
      return widget.index == controller.initialPage;
    }
    final position = controller.page ?? controller.initialPage.toDouble();
    // Smaller pages can expose more than two children in the same viewport.
    final visibleDistance = (1 + 1 / controller.viewportFraction) / 2;
    return (position - widget.index).abs() < visibleDistance;
  }

  void _updateVisibility() {
    final enabled = _isVisible;
    if (enabled != _enabled) {
      setState(() => _enabled = enabled);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateVisibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: _enabled, child: widget.child);
}
