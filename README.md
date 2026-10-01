# PiliPlus · Thread Ripper 分支

中文 | [English](README.en.md)

这是 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的分支。本页只说明相对上游的改动；原有功能和项目说明请看[上游 README](https://github.com/bggRGjQaUbCoE/PiliPlus#readme)。

## 相对上游的改动

- 在 Android、iOS、Windows、macOS、Linux 共用的播放器中集成 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) 多线程下载思路。
- 视频和音频共用并发限制，支持自动调节或手动选择 4、8、16、32 个请求，以及大陆、海外、自定义官方 CDN。
- 优先发送小块初始数据，后续数据按顺序及时送入播放器，减少开始播放前的缓冲等待；慢节点在 200 毫秒后尝试备用路线。
- 提供可单独开启的实验性 HLS 直播加速、分片预取，以及速度、并发数、重试和回退状态。
- 使用固定的 Android 分支签名密钥；应用内更新和下载均指向本仓库。

加速默认关闭。入口位于 **设置 → 音视频设置 → 线程撕裂者 · 多线程加速**，也可在视频播放器的设置面板和直播播放器菜单中找到。调整播放器内的设置会保留播放位置和暂停状态。

## 下载

本分支的安装包见 [Releases](https://github.com/alvinmhng/PiliPlus/releases/latest)。Android 提供 `arm64-v8a`、`armeabi-v7a`、`x86_64`；其他平台沿用上游的打包方式。

固定签名启用前的随机签名 APK，以及上游签名的 APK，不能直接覆盖安装本分支的新包。请先备份设置，再卸载旧包并安装本分支；之后的本分支版本可以正常覆盖更新。

## 维护与来源

- [加速功能说明](docs/thread-ripper.md)
- [固定签名与手动构建](docs/fork-maintenance.md)
- 继承上游 [GPL-3.0 许可](LICENSE)。Thread Ripper 的 MIT 许可随应用一同提供。
- 感谢 [PiliPlus 上游](https://github.com/bggRGjQaUbCoE/PiliPlus) 和 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)。
