# iPhone Mirror

macOS 上通过 USB 把 iPhone 画面投到电脑，并用键鼠操作。
不需要登录、不需要安装驱动、不依赖系统镜像组件。

## 功能

- 实时画面：H.264，约 30 fps
- 鼠标：单击、长按、拖动
- 键盘：普通按键与修饰键
- 工具栏：主屏 / 多任务 / 音量 / 静音 / 电源 / Siri / 粘贴 / 重置
- 窗口：置顶、透明度、比例锁定

## 安装

从 [Releases](../../releases) 下载 zip，解压后把 `iPhoneMirror.app` 拖进「应用程序」。

首次打开会被 Gatekeeper 拦截，任选一种放行：

- 右键点 App → 打开 → 再点「打开」
- 或终端执行 `xattr -dr com.apple.quarantine /Applications/iPhoneMirror.app`

安装包自带 Python 运行时和依赖，不需要另外装 Python。

## 环境要求

| 项目 | 要求 |
|---|---|
| macOS | 11 或更高 |
| iPhone | iOS 17 或更高 |
| 架构 | x86_64（Apple Silicon 通过 Rosetta 运行） |
| 连接 | 数据线，首次在手机上点「信任此电脑」 |

首次使用控制功能需要开发者镜像，程序会自动挂载（需联网）。

## 从源码构建

```bash
pip3 install pyusb pymobiledevice3 pyinstaller
./build.sh
open iPhoneMirror.app
```

构建脚本会打包 Python 运行时、编译播放器、签名并生成 zip。
建议用 python-build-standalone 的解释器（`IPM_PYTHON=...`），
避免二进制里带上本机用户名路径。

## 工作原理

```
iPhoneMirror.app（Swift 客户端）
   └─ Unix socket ← resident.py（USB 视频会话 + HID 隧道）
```

App 运行期间由 `resident.py` 独占 USB 会话并广播 H.264 帧；
App 关闭时它停止会话、把设备切回普通 USB 配置。
协议细节见 [docs/protocol.md](docs/protocol.md)。

## 已知限制

- 未做 Apple 公证，首次打开需要右键放行
- 运行期间占用 USB，QuickTime / 访达投屏会冲突
- 帧率由设备端决定（实测约 30 fps），主机端无法提高
- 强制结束 App 时，后台最多残留 60 秒后自动释放

## 声明

独立实现，不包含任何第三方软件的代码、二进制或美术资源。
协议字段与时序来自对 Apple USB 协议的互操作性分析。
