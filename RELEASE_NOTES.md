# v0.1 — macOS 首个可下载版本

## 下载

`iPhoneMirror-macOS-x86_64.zip`（约 49 MB，解压后 119 MB）

## 安装

1. 解压，把 `iPhoneMirror.app` 拖进「应用程序」
2. 首次打开会被 Gatekeeper 拦截，任选一种放行：
   - 右键点 App → 打开 → 再点「打开」
   - 或终端执行 `xattr -dr com.apple.quarantine /Applications/iPhoneMirror.app`
3. iPhone 用数据线连接 Mac，解锁并点「信任此电脑」

安装包自带 Python 运行时与全部依赖，不需要安装 Python。

## 功能

- 实时画面（H.264，约 30fps）
- 鼠标点击 / 长按 / 拖动
- 键盘输入，Esc 回主屏，Tab 多任务
- 工具栏：主屏 / 多任务 / 音量 / 静音 / 电源 / Siri / 粘贴 / 重置
- 窗口置顶、透明度、比例锁定

## 系统要求

- macOS 11 或更高
- iOS 17 或更高（HID 控制）
- 架构：x86_64（Apple Silicon 通过 Rosetta 运行）

## 已知限制

- 未做 Apple 公证，首次打开需要右键放行
- App 运行期间占用 USB，QuickTime / 访达投屏会冲突
- 首次使用控制功能需要联网下载开发者镜像
- 息屏可投屏，但 HID 注入需要设备解锁
