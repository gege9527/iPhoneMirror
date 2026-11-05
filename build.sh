#!/bin/bash
# 一键构建 iPhoneMirror.app 并生成 Release zip
# 依赖：Xcode 命令行工具、Python 3.10+（pyusb / pymobiledevice3 / pyinstaller）
#
# 建议用 python-build-standalone 之类的便携解释器（IPM_PYTHON=...），
# 因为它的二进制里不含本机用户名路径；用 pyenv / Homebrew 构建的解释器
# 会在 libpython 里留下 /Users/<name>/... 字符串。
set -euo pipefail
cd "$(dirname "$0")"

APP=iPhoneMirror.app
RES=$APP/Contents/Resources
PY=${IPM_PYTHON:-python3}

echo "==> 打包 Python 运行时"
$PY -m PyInstaller --noconfirm --clean --onedir --name runtime_entry \
  --hidden-import qtv_stream --hidden-import hid_daemon \
  --collect-all pymobiledevice3 --collect-submodules usb \
  runtime_entry.py

echo "==> 编译播放器"
swiftc -O player.swift -o player \
  -framework Cocoa -framework AVFoundation \
  -framework VideoToolbox -framework IOKit

echo "==> 组装 App"
cp player $APP/Contents/MacOS/iPhoneMirror
cp player $RES/player
cp resident.py qtv_stream.py hid_daemon.py launcher.sh $RES/
rm -rf $RES/runtime
cp -R dist/runtime_entry $RES/runtime
rm -rf $RES/__pycache__

echo "==> 签名（ad-hoc，本地自用）"
codesign --force --deep --sign - $APP
codesign --verify --deep --strict $APP

echo "==> 生成 zip"
rm -f iPhoneMirror-macOS-x86_64.zip
ditto -c -k --keepParent $APP iPhoneMirror-macOS-x86_64.zip

ls -lh iPhoneMirror-macOS-x86_64.zip
echo "完成"
