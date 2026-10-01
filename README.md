# PiliPlus · Thread Ripper 分支

中文 | [English](README.en.md)

这是 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的分支。本页只说明相对上游的改动；原有功能和项目说明请看[上游 README](https://github.com/bggRGjQaUbCoE/PiliPlus#readme)。

## 相对上游的改动

- 在 Android、iOS、Windows、macOS、Linux 共用的播放器中集成 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) 多线程下载思路。
- 视频和音频共用并发限制，支持自动调节或手动选择 4、8、16、32 个请求，以及大陆、海外、自定义官方 CDN。
- 合并元数据探测与首块媒体请求，复用连接并持续补充下载窗口，减少起播缓冲；慢节点在 120 毫秒后尝试备用路线。
- 使用加权 CDN 调度、分块断点续传和根据缓冲状态调整的自动并发，同时保留原始路线回退。
- 提供可单独开启的实验性 HLS 直播加速、分片预取，以及速度、并发数、重试和回退状态。
- 使用固定的 Android 分支签名密钥；应用内更新和下载均指向本仓库。

加速默认关闭。入口位于 **设置 → 音视频设置 → 线程撕裂者 · 多线程加速**，也可在视频播放器的设置面板和直播播放器菜单中找到。调整播放器内的设置会保留播放位置和暂停状态。

## 说明与来源

- [加速功能说明](docs/thread-ripper.md)
- 继承上游 [GPL-3.0 许可](LICENSE)。Thread Ripper 的 MIT 许可随应用一同提供。
- 感谢 [PiliPlus 上游](https://github.com/bggRGjQaUbCoE/PiliPlus)、[Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)，以及提供视频下载调度和回归测试参考的 [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus)。
