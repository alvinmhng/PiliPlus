import 'dart:io' show Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

abstract final class Update {
  /// Fork artifacts include their Git revision count. Compare that build number
  /// before timestamps so the installed release never offers to update itself.
  static bool isNewerRelease(
    Map data, {
    int versionCode = BuildConfig.versionCode,
    String commitHash = BuildConfig.commitHash,
    int buildTime = BuildConfig.buildTime,
  }) {
    if (data['target_commitish'] == commitHash) return false;
    final assets = data['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map || asset['name'] is! String) continue;
        final match = RegExp(r'\+(\d+)(?=[_.])').firstMatch(asset['name']);
        final code = match == null ? null : int.tryParse(match[1]!);
        if (code != null) return code > versionCode;
      }
    }
    final timestamp = data['created_at'];
    final date = timestamp is String ? DateTime.tryParse(timestamp) : null;
    return date != null && date.millisecondsSinceEpoch ~/ 1000 > buildTime;
  }

  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is! Map || res.data['tag_name'] is! String) {
        if (!isAuto) {
          SmartDialog.showToast('检查更新失败，GitHub接口未返回数据，请检查网络');
        }
        return;
      }
      final data = res.data as Map;
      if (!isNewerRelease(data)) {
        if (!isAuto) {
          SmartDialog.showToast('已是最新版本');
        }
      } else {
        SmartDialog.show(
          animationType: SmartAnimationType.centerFade_otherSlide,
          builder: (context) {
            final colorScheme = ColorScheme.of(context);
            Widget downloadBtn(String text, {String? ext}) => TextButton(
              onPressed: () => onDownload(data, ext: ext),
              child: Text(text),
            );
            return AlertDialog(
              title: const Text('🎉 发现新版本 '),
              content: SizedBox(
                height: 280,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${data['tag_name']}',
                        style: const TextStyle(fontSize: 20),
                      ),
                      const SizedBox(height: 8),
                      Text('${data['body']}'),
                      TextButton(
                        onPressed: () => PageUtils.launchURL(
                          '${Constants.sourceCodeUrl}/commits/main',
                        ),
                        child: Text(
                          "点此查看完整更新(即commit)内容",
                          style: TextStyle(color: colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (isAuto)
                  TextButton(
                    onPressed: () {
                      SmartDialog.dismiss();
                      GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                    },
                    child: Text(
                      '不再提醒',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  ),
                TextButton(
                  onPressed: SmartDialog.dismiss,
                  child: Text(
                    '取消',
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
                if (Platform.isWindows) ...[
                  downloadBtn('zip', ext: 'zip'),
                  downloadBtn('exe', ext: 'exe'),
                ] else if (Platform.isLinux) ...[
                  downloadBtn('rpm', ext: 'rpm'),
                  downloadBtn('deb', ext: 'deb'),
                  downloadBtn('targz', ext: 'tar.gz'),
                ] else
                  downloadBtn('Github'),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      void download(String plat) {
        if (data['assets'].isNotEmpty) {
          for (Map<String, dynamic> i in data['assets']) {
            final String name = i['name'];
            if (name.contains(plat) &&
                (ext == null || ext.isEmpty ? true : name.endsWith(ext))) {
              PageUtils.launchURL(i['browser_download_url']);
              return;
            }
          }
          throw UnsupportedError('platform not found: $plat');
        }
      }

      if (Platform.isAndroid) {
        // 获取设备信息
        AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
        // [arm64-v8a]
        download(androidInfo.supportedAbis.first);
      } else {
        download(Platform.operatingSystem);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
      PageUtils.launchURL('${Constants.sourceCodeUrl}/releases/latest');
    }
  }
}
