/// Owns a single asynchronous chat startup without reviving a closed owner.
class LiveMessageStartup<T> {
  int _generation = 0;
  int? _pending;
  bool _wanted = false;
  bool _disposed = false;

  bool get wanted => _wanted && !_disposed;

  Future<void> start({
    required Future<T?> Function() load,
    required bool Function() connected,
    required void Function(T) connect,
    void Function(Object, StackTrace)? onError,
  }) async {
    if (_disposed) return;
    _wanted = true;
    if (_pending != null || connected()) return;
    final generation = _generation;
    _pending = generation;
    try {
      final data = await load();
      if (data != null && wanted && generation == _generation && !connected()) {
        connect(data);
      }
    } catch (error, stack) {
      if (wanted && generation == _generation) onError?.call(error, stack);
    } finally {
      // An older completion must not clear a replacement startup's guard.
      if (_pending == generation) _pending = null;
    }
  }

  void stop() {
    _wanted = false;
    _generation++;
    _pending = null;
  }

  void dispose() {
    stop();
    _disposed = true;
  }
}

/// Retains changes without rebuilding a hidden list, then refreshes it once.
class DeferredLiveUpdates {
  DeferredLiveUpdates(this._refresh);

  final void Function() _refresh;
  bool visible = false;
  bool dirty = false;

  void changed({bool notify = true}) {
    dirty = true;
    if (notify) refresh();
  }

  bool refresh() {
    if (!visible || !dirty) return false;
    dirty = false;
    _refresh();
    return true;
  }
}

/// Releases old message objects while preserving the live sliver's indices.
/// Null slots remain because changing indices would disturb scroll restoration.
/// A hidden list retains its rendered rows until its scroll position advances.
class LiveChatHistory {
  LiveChatHistory({
    required this.retain,
    required this.overflow,
    required this.safeMargin,
  });

  final int retain;
  final int overflow;
  final int safeMargin;
  int trimmed = 0;

  void trim(List<dynamic> messages, {required int renderedIndex}) {
    final end = messages.length - retain;
    if (renderedIndex - end > safeMargin &&
        messages.length - trimmed > retain + overflow) {
      messages.fillRange(trimmed, end);
      trimmed = end;
    }
  }
}
