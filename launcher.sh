#!/bin/bash
# 约束：
# 1) 父进程(iPhoneMirror)退出 -> 自己立即退出，绝不留孤儿
# 2) 不忽略 HUP/TERM，任何终止信号都清理子进程
# 3) 重启上限 5 次，避免无限循环烧 CPU
# 4) mkdir 原子锁，杜绝多实例
DIR="$(cd "$(dirname "$0")" && pwd)"
PY_CHECK='import usb, pymobiledevice3'
pick_py() {
  for c in "${IPM_PYTHON:-}" "$HOME/.pyenv/shims/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    "$c" -c "$PY_CHECK" >/dev/null 2>&1 && { echo "$c"; return; }
  done
}
PY=$(pick_py)
[ -n "$PY" ] || PY=/usr/bin/python3
LOG=/tmp/iphonemirror.log
HLOG=/tmp/iphonemirror.hid.log
LOCK=/tmp/iphonemirror.launcher.pid
LOCKDIR="${LOCK}.d"
PARENT=$PPID

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OLD=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && [ "$OLD" != "$$" ]; then
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
echo $$ > "$LOCK"

HP=""
VP=""
cleanup() {
  [ -n "$HP" ] && kill "$HP" 2>/dev/null
  [ -n "$VP" ] && kill "$VP" 2>/dev/null
  pkill -f "$DIR/hid_daemon.py" 2>/dev/null
  pkill -f "$DIR/qtv_stream.py" 2>/dev/null
  rm -rf "$LOCKDIR"
  rm -f "$LOCK"
  exit 0
}
trap cleanup INT TERM HUP EXIT

parent_alive() { kill -0 "$PARENT" 2>/dev/null; }

pkill -f "$DIR/hid_daemon.py" 2>/dev/null
pkill -f "$DIR/qtv_stream.py" 2>/dev/null
sleep 0.5
> "$HLOG"

HID_OK=1
if "$PY" -m pymobiledevice3 usbmux list 2>/dev/null | grep -qE '"ProductVersion": *"1[0-6]\.'; then
  HID_OK=0
  echo "=== iOS < 17：只投屏 ===" >>"$LOG"
fi

restarts=0
while parent_alive && [ "$restarts" -lt 5 ]; do
  "$PY" "$DIR/qtv_stream.py" 86400 2>"$LOG" &
  VP=$!
  for i in $(seq 1 60); do
    parent_alive || cleanup
    cfg=$("$PY" -c "import usb.core;d=usb.core.find(idVendor=0x05ac,idProduct=0x12a8);print(d.get_active_configuration().bConfigurationValue if d else 0)" 2>/dev/null)
    [ "$cfg" = "7" ] && break
    sleep 0.25
  done
  sleep 1
  if [ "$HID_OK" = "1" ]; then
    # HID 依赖开发者镜像；重启手机后镜像会丢。
    # 用 mounter list 做快速判断（比 get-display-info 建隧道快得多）
    if ! "$PY" -m pymobiledevice3 mounter list 2>/dev/null | grep -q "dmg"; then
      echo "=== developer image missing, mounting ===" >>"$LOG"
      # 可选：设置 IPM_PROXY 走代理下载开发者镜像
      [ -n "$IPM_PROXY" ] && export https_proxy="$IPM_PROXY" http_proxy="$IPM_PROXY"
      "$PY" -m pymobiledevice3 mounter auto-mount >>"$LOG" 2>&1
    fi
    pkill -f "$DIR/hid_daemon.py" 2>/dev/null
    "$PY" "$DIR/hid_daemon.py" >"$HLOG" 2>&1 &
    HP=$!
  fi
  while kill -0 "$VP" 2>/dev/null; do
    if ! parent_alive; then cleanup; fi
    sleep 0.7
  done
  [ -n "$HP" ] && kill "$HP" 2>/dev/null
  restarts=$((restarts+1))
  [ "$restarts" -lt 5 ] && sleep 2
done

cleanup
