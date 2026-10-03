import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:material_ui/material_ui.dart';

/// Keeps hidden canvases idle and rejects comments that cannot be displayed.
class EnergyAwareDanmaku<T> extends StatefulWidget {
  const EnergyAwareDanmaku({
    super.key,
    required this.enabled,
    required this.playing,
    required this.opacity,
    required this.option,
    required this.size,
    required this.createdController,
  });

  final bool enabled;
  final bool playing;
  final double opacity;
  final DanmakuOption option;
  final Size size;
  final ValueChanged<DanmakuController<T>> createdController;

  @override
  State<EnergyAwareDanmaku<T>> createState() => _EnergyAwareDanmakuState<T>();
}

class _EnergyAwareDanmakuState<T> extends State<EnergyAwareDanmaku<T>> {
  DanmakuController<T>? _controller;

  bool get _visible => widget.enabled && widget.opacity > 0;
  bool get _active => _visible && widget.playing;

  void _synchronize() {
    final controller = _controller;
    if (controller == null) return;
    if (!_visible) {
      controller
        ..pause()
        ..clear();
    } else if (!widget.playing) {
      controller.pause();
    } else {
      controller.resume();
    }
  }

  void _created(DanmakuController<T> controller) {
    _controller = controller;
    _synchronize();
    widget.createdController(
      DanmakuController<T>(
        addDanmaku: (item) {
          if (!mounted || !_active) return false;
          if (!controller.running) controller.resume();
          return controller.addDanmaku(item);
        },
        updateOption: controller.updateOption,
        pause: controller.pause,
        resume: () {
          if (mounted && _active) {
            controller.resume();
          } else {
            controller.pause();
          }
        },
        clear: controller.clear,
        getOption: controller.getOption,
        isRunning: controller.isRunning,
        findDanmaku: controller.findDanmaku,
        findSingleDanmaku: controller.findSingleDanmaku,
        getTrackCount: controller.getTrackCount,
        scrollDanmaku: controller.scrollDanmaku,
        staticDanmaku: controller.staticDanmaku,
        specialDanmaku: controller.specialDanmaku,
      ),
    );
  }

  @override
  void didUpdateWidget(EnergyAwareDanmaku<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.option != widget.option) {
      _controller?.updateOption(widget.option);
    }
    _synchronize();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _visible ? widget.opacity : 0,
    duration: const Duration(milliseconds: 100),
    child: TickerMode(
      enabled: _active,
      child: DanmakuScreen<T>(
        createdController: _created,
        option: widget.option,
        size: widget.size,
      ),
    ),
  );
}
