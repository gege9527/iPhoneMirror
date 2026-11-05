#!/usr/bin/env python3
"""常驻 HID 注入守护进程：FIFO 事件 -> iOS 触摸 / 按键"""
import asyncio, os, sys, time, threading, queue, subprocess

FIFO = "/tmp/iphonemirror.input"
q: "queue.Queue[str]" = queue.Queue()
aq: "asyncio.Queue[str]" = asyncio.Queue()   # 事件驱动队列，零轮询延迟
loop_ref = None

def ensure_fifo():
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO, 0o600)

def reader():
    """读 FIFO，用 call_soon_threadsafe 直接投递到事件循环（不做轮询）"""
    while True:
        try:
            with open(FIFO, "r") as f:
                for line in f:
                    s = line.strip()
                    if not s:
                        continue
                    if loop_ref is not None:
                        loop_ref.call_soon_threadsafe(aq.put_nowait, s)
                    else:
                        q.put(s)
        except Exception:
            time.sleep(0.3)

async def main():
    from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd
    from pymobiledevice3.remote.core_device.hid_service import (
        UniversalHIDServiceService, IndigoHIDService,
        build_touchscreen_report, build_keyboard_report,
        HID_BUTTON_STATE_DOWN, HID_BUTTON_STATE_UP)

    global loop_ref
    loop_ref = asyncio.get_running_loop()
    ensure_fifo()
    threading.Thread(target=reader, daemon=True).start()
    print("connecting tunnel...", flush=True)
    # 优先 macOS 原生隧道（骑 Apple 自己的 remotepairingd，比自建隧道稳定）
    rsd = None
    try:
        from pymobiledevice3.remote import native_tunnel
        rsd = await native_tunnel.establish_native_rsd()
        print("native tunnel up", flush=True)
    except Exception as e:
        print("native tunnel failed:", type(e).__name__, e, flush=True)
        rsd = await establish_userspace_rsd()
        print("userspace tunnel up", flush=True)

    HOME = (0x0C, 0x40)
    def _home_tap_hold():
        pass

    from pymobiledevice3.remote.core_device.orientation_service import OrientationService
    async with UniversalHIDServiceService(rsd) as svc, IndigoHIDService(rsd) as indigo:
        print("hid ready", flush=True)

        STATE = "/tmp/iphonemirror.orient"

        def write_state(dev, iface):
            try:
                import json as _json
                with open(STATE, "w") as f:
                    _json.dump({"device": dev, "interface": iface}, f)
            except Exception as e:
                print("state write err", e, flush=True)

        async def read_interface_orientation():
            """SpringBoard 当前界面方向（主屏锁竖屏时这里是 PORTRAIT）"""
            try:
                from pymobiledevice3.services.springboard import SpringBoardServicesService
                async with SpringBoardServicesService(rsd) as sb:
                    o = await sb.get_interface_orientation()
                    return o.name
            except Exception as e:
                print("iface query err", type(e).__name__, e, flush=True)
                return ""

        async def orientation_watch():
            while True:
                try:
                    iface = await read_interface_orientation()
                    write_state(last_device_orientation[0], iface)
                except Exception:
                    pass
                await asyncio.sleep(1.5)

        last_device_orientation = ["portrait"]

        async def set_orientation(want_landscape):
            """转到指定方向（不是步进旋转）：竖=portrait，横=landscapeLeft"""
            try:
                async with OrientationService(rsd) as o:
                    for _ in range(5):
                        r = await o.rotate("left")
                        cur = r.get("currentDeviceOrientation", "")
                        print("orient:", cur, flush=True)
                        last_device_orientation[0] = cur
                        if want_landscape and cur == "landscapeLeft":
                            iface = await read_interface_orientation()
                            write_state(cur, iface)
                            return cur
                        if not want_landscape and cur == "portrait":
                            iface = await read_interface_orientation()
                            write_state(cur, iface)
                            return cur
                    return None
            except Exception as e:
                print("rotate err", type(e).__name__, e, flush=True)
                return None

        async def home_press(hold=0.05):
            await indigo.send_button(*HOME, HID_BUTTON_STATE_DOWN)
            await asyncio.sleep(hold)
            await indigo.send_button(*HOME, HID_BUTTON_STATE_UP)

        # orientation_watch 已停用(旋转功能移除)
        errs = 0
        while True:
            # 事件驱动：有事件立刻处理；空闲 3 秒做一次隧道心跳，
            # 否则 USB 配置切换把隧道踢断后这里会永远静默挂起
            try:
                line = await asyncio.wait_for(aq.get(), timeout=3.0)
            except asyncio.TimeoutError:
                try:
                    from pymobiledevice3.services.springboard import SpringBoardServicesService
                    async with SpringBoardServicesService(rsd) as sb:
                        await sb.get_interface_orientation()
                except Exception as e:
                    print("tunnel heartbeat failed:", type(e).__name__, e, flush=True)
                    raise RuntimeError("tunnel dead")
                continue
            parts = line.split()
            if not parts: continue
            cmd = parts[0]
            # 附带取出队列里已到达的其它事件（批量，降低 down/up 间隔）
            batch = [parts]
            while len(batch) < 8:
                try:
                    batch.append(aq.get_nowait().split())
                except asyncio.QueueEmpty:
                    break
            try:
                if cmd == "click" and len(parts) == 3:
                    # 原子点击：contact + release 一次发完，间隔 8ms，避免被判成长按
                    x, y = int(parts[1]), int(parts[2])
                    await svc.send_report(257, build_touchscreen_report(0xC2, x, y))
                    await asyncio.sleep(0.008)
                    await svc.send_report(257, build_touchscreen_report(0x02, x, y))
                    errs = 0
                elif cmd in ("down", "move") and len(parts) == 3:
                    x, y = int(parts[1]), int(parts[2])
                    await svc.send_report(257, build_touchscreen_report(0xC2, x, y))
                elif cmd == "up":
                    x, y = (int(parts[1]), int(parts[2])) if len(parts) == 3 else (32768, 32768)
                    await svc.send_report(257, build_touchscreen_report(0x02, x, y))
                elif cmd == "back":   # 左边缘右滑 = 返回上一级
                    await svc.send_report(257, build_touchscreen_report(0xC2, 0, 32768))
                    await asyncio.sleep(0.02)
                    for x in range(1500, 30000, 1500):
                        await svc.send_report(257, build_touchscreen_report(0xC2, x, 32768))
                        await asyncio.sleep(0.015)
                    await svc.send_report(257, build_touchscreen_report(0x02, 30000, 32768))
                elif cmd == "home":
                    await home_press()
                elif cmd == "switch":     # 双击 home = App 切换器
                    await home_press(0.05)
                    await asyncio.sleep(0.12)
                    await home_press(0.05)
                elif cmd in ("volume_up", "volume_down", "mute", "siri", "lock"):
                    usage = {"volume_up": (0x0C, 0xE9, 0.05),
                             "volume_down": (0x0C, 0xEA, 0.05),
                             "mute": (0x0C, 0xE2, 0.05),
                             "siri": (0x0C, 0xCF, 1.0),
                             "lock": (0x0C, 0x30, 0.5)}[cmd]
                    await indigo.send_button(usage[0], usage[1], HID_BUTTON_STATE_DOWN)
                    await asyncio.sleep(usage[2])
                    await indigo.send_button(usage[0], usage[1], HID_BUTTON_STATE_UP)
                elif cmd == "landscape":
                    await set_orientation(True)
                elif cmd == "portrait":
                    await set_orientation(False)
                elif cmd == "key" and len(parts) == 2:
                    codes = [int(x, 0) for x in parts[1].split(",") if x]
                    await svc.send_report(512, build_keyboard_report(codes))
                    await asyncio.sleep(0.02)
                    await svc.send_report(512, build_keyboard_report([]))
            except Exception as e:
                errs += 1
                print("inject err", e, flush=True)
                if errs >= 3:
                    # 隧道已死但服务对象还活着：抛出后由 run_forever 重建
                    raise RuntimeError("hid session dead")

async def run_forever():
    """隧道断开后自动重建，设备拔插不需要重启 App"""
    fails = 0
    while True:
        try:
            await main()
            fails = 0
        except (asyncio.CancelledError, KeyboardInterrupt):
            raise
        except Exception as e:
            print("session ended:", type(e).__name__, e, flush=True)
        # 刚启动时快速重试（配置切换后马上就能连上），连续失败再退避
        delay = 1.0 if fails < 3 else 6.0
        fails += 1
        print(f"reconnecting in {delay:g}s...", flush=True)
        await asyncio.sleep(delay)

def run():
    try:
        asyncio.run(run_forever())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    run()
