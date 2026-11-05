#!/usr/bin/env python3
"""打包后的统一入口：runtime_entry [resident|hid]

PyInstaller 只能有一个入口，所以用子命令分发：
  runtime_entry           → resident 会话进程
  runtime_entry hid       → HID 注入进程（由 resident 拉起）
"""
import sys


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "resident"
    if cmd == "hid":
        import hid_daemon
        hid_daemon.run()
        return 0
    import resident
    return resident.main()


if __name__ == "__main__":
    sys.exit(main())
