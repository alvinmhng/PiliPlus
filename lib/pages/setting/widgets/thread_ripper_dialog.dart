import 'package:PiliPlus/models/common/video/thread_ripper.dart';
import 'package:PiliPlus/services/thread_ripper/proxy.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

Future<bool?> showThreadRipperDialog(
  BuildContext context, {
  ValueListenable<ThreadRipperStats>? stats,
  bool reloadOnSave = false,
  bool isLive = false,
}) => showDialog<bool>(
  context: context,
  builder: (_) => ThreadRipperSettingsDialog(
    stats: stats,
    reloadOnSave: reloadOnSave,
    isLive: isLive,
  ),
);

class ThreadRipperSettingsDialog extends StatefulWidget {
  const ThreadRipperSettingsDialog({
    super.key,
    this.stats,
    this.reloadOnSave = false,
    this.isLive = false,
  });
  final ValueListenable<ThreadRipperStats>? stats;
  final bool reloadOnSave;
  final bool isLive;

  @override
  State<ThreadRipperSettingsDialog> createState() =>
      _ThreadRipperSettingsDialogState();
}

class _ThreadRipperSettingsDialogState
    extends State<ThreadRipperSettingsDialog> {
  late final _saved = Pref.threadRipper;
  late bool _enabled = _saved.enabled;
  late bool _live = _saved.liveEnabled;
  late ThreadRipperCdnMode _mode = _saved.mode;
  late int _concurrency = _saved.concurrency;
  late final _hosts = TextEditingController(
    text: _saved.customHosts.join('\n'),
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _hosts.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final hosts = _hosts.text
        .split(RegExp(r'[\s,，;；]+'))
        .where((value) => value.isNotEmpty)
        .toList();
    if (hosts.length > 32 ||
        hosts.any((host) => ThreadRipperCdn.normalizeHost(host) == null)) {
      setState(
        () => _error = '最多 32 个 CDN；请输入 bilivideo.com / cn / net 或 akamaized.net 的 HTTPS 主机名',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await GStorage.setting.put(SettingBoxKey.threadRipper, {
        'enabled': _enabled,
        'liveEnabled': _live,
        'mode': _mode.name,
        'concurrency': _concurrency,
        'customHosts': hosts
            .map(ThreadRipperCdn.normalizeHost)
            .whereType<String>()
            .toSet()
            .toList(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '无法保存设置，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('线程撕裂者'),
      constraints: const BoxConstraints(maxWidth: 480),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('并发下载与 CDN 调度，适合海外或高码率视频。可能增加耗电和流量。'),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('开启多线程加速'),
                value: _enabled,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _enabled = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('直播加速（实验）'),
                subtitle: const Text('优先 HLS 分片路线；若播放异常可单独关闭'),
                value: _live,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _live = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ThreadRipperCdnMode>(
                initialValue: _mode,
                decoration: const InputDecoration(labelText: '加速 CDN 路线'),
                items: [
                  for (final mode in ThreadRipperCdnMode.values)
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _mode = value!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _concurrency,
                decoration: const InputDecoration(labelText: '并发线程上限'),
                items: [
                  for (final count in ThreadRipperOptions.threadCounts)
                    DropdownMenuItem(
                      value: count,
                      child: Text(count == 0 ? '自动（推荐，8–32）' : '$count 线程'),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _concurrency = value!),
              ),
              if (_mode == ThreadRipperCdnMode.custom) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _hosts,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '自定义 CDN 主机（每行一个）',
                    hintText: 'upos-sz-mirrorali.bilivideo.com',
                    helperText: '留空时使用大陆 CDN',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                widget.reloadOnSave
                    ? widget.isLive
                          ? '保存后重新加载当前直播。'
                          : '保存后重新加载当前播放，保留播放位置。'
                    : '保存后下次加载视频或直播时生效。',
              ),
              if (widget.stats case final stats?) ...[
                const Divider(height: 24),
                ValueListenableBuilder<ThreadRipperStats>(
                  valueListenable: stats,
                  builder: (_, value, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(value.status),
                      Text(
                        '${value.activeThreads} / ${value.threadLimit} 线程 · ${(value.bytesPerSecond / 1048576).toStringAsFixed(2)} MB/s',
                      ),
                      Text(
                        '已下载 ${(value.downloadedBytes / 1048576).toStringAsFixed(1)} MB · 重试 ${value.retries} · 回退 ${value.fallbacks}',
                      ),
                      if (value.lastHost.isNotEmpty)
                        Text(
                          value.lastHost,
                          style: TextTheme.of(context).bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: ColorScheme.of(context).error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
