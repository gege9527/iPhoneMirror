#!/usr/bin/env python3
"""常驻投屏链路：App 退出后保持 USB 会话，App 重开秒连。

职责：
  1) 独占 USB 视频会话（QuickTime 协议），把 Annex-B 帧广播到 Unix socket
  2) 托管 HID 注入进程 hid_daemon.py（隧道不再随 App 退出重建）
  3) 无客户端空闲 IDLE_SECS 后优雅关闭 AV 会话并退出

协议实现复用同目录的 qtv_stream.py，避免两份逻辑漂移。
"""
import os, sys, time, socket, struct, threading, signal, subprocess

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import qtv_stream as Q

SOCK = "/tmp/iphonemirror.resident.sock"
PIDF = "/tmp/iphonemirror.resident.pid"
HLOG = "/tmp/iphonemirror.hid.log"
HID = os.path.join(BASE, "hid_daemon.py")
PY = sys.executable
# App 正常退出会直接 SIGTERM 本进程；这里的空闲超时只是「App 崩溃没来得及通知」的兜底。
# 默认 60 秒：超过就自动关闭 AV 会话并切回 cfg 3，恢复普通 USB 状态。
IDLE_SECS = int(os.environ.get("IPM_IDLE", "60"))


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def acquire_lock():
    try:
        with open(PIDF) as f:
            old = int(f.read().strip())
        if old != os.getpid():
            os.kill(old, 0)
            log("resident already running:", old)
            return False
    except Exception:
        pass
    with open(PIDF, "w") as f:
        f.write(str(os.getpid()))
    return True


def has_idr(annexb):
    i = 0
    while True:
        i = annexb.find(b"\x00\x00\x00\x01", i)
        if i < 0 or i + 4 >= len(annexb):
            return False
        if annexb[i + 4] & 0x1F == 5:
            return True
        i += 4


class Hub:
    """帧广播 + GOP 缓存：新客户端连上立刻补最近 IDR 起的帧"""

    def __init__(self):
        self.clients = []
        self.lock = threading.Lock()
        self.last_client = time.time()
        self.ps = b""
        self.gop = []
        self.gop_bytes = 0

    def add(self, c):
        with self.lock:
            self.clients.append(c)
            self.last_client = time.time()
            ps, gop = self.ps, list(self.gop)
        log("client attached:", gop and len(gop), "gop")
        try:
            if ps:
                c.sendall(ps)
            for f in gop:
                c.sendall(f)
        except Exception:
            self.remove(c, "handshake")

    def remove(self, c, why=""):
        with self.lock:
            if c in self.clients:
                self.clients.remove(c)
            if not self.clients:
                # 冷却窗口从「最后一个客户端断开」开始算，而不是从连上算
                self.last_client = time.time()
        try:
            c.close()
        except Exception:
            pass
        log("client detached:", why)

    def client_count(self):
        with self.lock:
            return len(self.clients)

    def drop_all(self):
        with self.lock:
            clients = list(self.clients)
            self.clients = []
        for c in clients:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                c.close()
            except Exception:
                pass

    def note_ps(self, ps):
        if not ps:
            return
        with self.lock:
            changed = ps != self.ps
            self.ps = ps
            clients = list(self.clients) if changed else []
        for c in clients:
            try:
                c.sendall(ps)
            except Exception:
                self.remove(c, "ps-write")

    def push(self, data, is_idr):
        with self.lock:
            if is_idr or not self.gop:
                self.gop = [data]
                self.gop_bytes = len(data)
            else:
                self.gop.append(data)
                self.gop_bytes += len(data)
                while self.gop_bytes > 8 * 1024 * 1024 and len(self.gop) > 1:
                    self.gop_bytes -= len(self.gop.pop(0))
            clients = list(self.clients)
            self.last = time.time()
        dead = []
        for c in clients:
            try:
                c.sendall(data)
            except Exception:
                dead.append(c)
        for c in dead:
            self.remove(c, "write-error")


def listener(hub, stop):
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o600)
    srv.listen(4)
    srv.settimeout(1.0)
    log("listening", SOCK)
    try:
        while not stop.is_set():
            try:
                c, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            c.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
            c.settimeout(0.5)
            hub.add(c)
    finally:
        srv.close()


hid_proc = None


def start_hid(force=False):
    global hid_proc
    if not force and hid_proc is not None and hid_proc.poll() is None:
        return
    if force:
        # 配置切换一定会踢断 HID 隧道，视频会话重建后必须重启注入进程
        stop_hid()
    # 打包后（PyInstaller）用自身可执行 + 子命令拉起，否则用 python 脚本
    if getattr(sys, "frozen", False):
        cmd = [sys.executable, "hid"]
    else:
        cmd = [PY, HID]
    try:
        hid_proc = subprocess.Popen(cmd, stdout=open(HLOG, "a"),
                                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        log("hid daemon started", hid_proc.pid)
    except Exception as e:
        log("hid start failed", e)


def stop_hid():
    global hid_proc
    if hid_proc is not None:
        try:
            hid_proc.terminate()
            hid_proc.wait(2)
        except Exception:
            pass
        hid_proc = None


def rply_dict(corr, dd):
    return struct.pack("<I", 20 + len(dd)) + Q.RPLY + struct.pack("<Q", corr) + struct.pack("<I", 0) + dd


HPD_DICT = None


def hpd_dict():
    global HPD_DICT
    if HPD_DICT is None:
        HPD_DICT = Q.make_dict([
            ("Valeria", Q.val_bool(True)),
            ("HEVCDecoderSupports444", Q.val_bool(True)),
            ("DisplaySize", Q.make_dict([("Width", Q.val_num(Q.num_f64(1920.0))),
                                         ("Height", Q.val_num(Q.num_f64(1200.0)))])),
        ])
    return HPD_DICT


def run(hub, session, stop=None):
    d, ifn, ein, eout = session
    t0 = time.time(); frames = 0; need = None; pinged = 0; idle = 0
    while True:
        if stop is not None and stop.is_set():
            log("signal stop")
            break
        if hub.client_count() == 0 and time.time() - hub.last_client > IDLE_SECS:
            log("idle timeout, shutdown")
            break
        try:
            b = bytes(d.read(ein, 262144, timeout=700))
        except Q.usb.core.USBTimeoutError:
            idle += 1
            if idle >= 2 and frames == 0 and pinged == 0:
                log("stalled: no PING after ~1.2s")   # 设备端 AV 会话残留，需要重新激活
                return "stalled"
            if idle >= 13:
                if hub.client_count() > 0 or frames == 0:
                    log("no data 9s, exit"); break
                log("no data 9s (idle, stay)"); idle = 0

            continue
        except Q.usb.core.USBError as e:
            log("usb", e); break
        idle = 0
        if len(b) < 8:
            continue
        m = b[4:8]
        if m == Q.PING:
            d.write(eout, b, timeout=800); pinged += 1
            if pinged == 1:
                time.sleep(0.05)
                d.write(eout, Q.asyn_dict(Q.EMPTY, b"1dph", hpd_dict()), timeout=800)
            continue
        if m == Q.SYNC:
            sub = b[16:20]; corr = Q.u64(b, 20); name = sub[::-1].decode('latin1')
            if name == "cwpa":
                d.write(eout, Q.rply_clock(corr, Q.CLK1), timeout=800)
            elif name == "afmt":
                dd = Q.make_dict([("Error", Q.val_num(Q.num_u32(0)))])
                d.write(eout, rply_dict(corr, dd), timeout=800)
            elif name == "cvrp":
                dv = Q.u64(b, 28)
                ps = Q.extract_ps(b)
                d.write(eout, Q.rply_clock(corr, Q.CLK2), timeout=800)
                time.sleep(0.03)
                d.write(eout, Q.asyn_dict(Q.EMPTY, b"1dph", hpd_dict()), timeout=800)
                need = Q.asyn_plain(dv, b"deen"); time.sleep(0.03)
                d.write(eout, need, timeout=800)
                hub.note_ps(ps)
            elif name == "clok":
                d.write(eout, Q.rply_clock(corr, Q.CLK2), timeout=800)
            elif name == "time":
                d.write(eout, Q.rply_time(corr, Q.cmtime(time.time_ns())), timeout=800)
            elif name == "stop":
                d.write(eout, Q.rply_clock(corr, 0), timeout=800)
            else:
                d.write(eout, Q.rply_clock(corr, Q.CLK1), timeout=800)
            continue
        if m == Q.ASYN:
            name = b[16:20][::-1].decode('latin1')
            if name == "feed":
                nalu = Q.parse_sbuf(b[20:])
                if nalu:
                    ann = Q.avcc_to_annexb(nalu)
                    hub.push(ann, has_idr(ann))
                    frames += 1
                if need:
                    d.write(eout, need, timeout=800)
            continue
    log("frames", frames, "elapsed", round(time.time() - t0, 1))
    return "ok"


def graceful_close(d, ifn, ein, eout, restore=True):
    try:
        for m in (b"0dph", b"0aph"):
            d.write(eout, Q.asyn_plain(Q.EMPTY, m), timeout=500)
        time.sleep(0.15)
    except Exception as e:
        log("close msg err", type(e).__name__, e)
    try:
        Q.usb.util.release_interface(d, ifn)
    except Exception as e:
        log("release err", type(e).__name__, e)

    if not restore:
        return
    # 切回 usbmux 配置才算真正干净退出：否则设备端停留在「录制中」，
    # 下次 quick_attach 虽然能 claim，但设备一个字节都不发（实测必现）
    for attempt in range(3):
        try:
            time.sleep(0.3)
            d2 = Q.find_retry(3, 0.2)
            if d2 is None:
                log("restore: device gone")
                return
            if Q.set_cfg_safe(d2, 3):
                log("restored cfg 3")
                return
            log("restore attempt", attempt + 1, "failed")
        except Exception as e:
            log("restore err", type(e).__name__, e)
    log("restore gave up, cfg may stay at 7")


def main():
    if not acquire_lock():
        return 0
    stop = threading.Event()
    hub = Hub()
    signal.signal(signal.SIGTERM, lambda s, f: stop.set())
    signal.signal(signal.SIGINT, lambda s, f: stop.set())

    threading.Thread(target=listener, args=(hub, stop), daemon=True).start()

    session = None
    try:
        while not stop.is_set():
            if session is None:
                log("open video session...")
                session = Q.open_session()
                if session is None:
                    log("open session failed, retry in 6s")
                    time.sleep(6)
                    continue
                log("video session up")
                time.sleep(1)
                start_hid(force=True)
            stalled = False
            try:
                stalled = run(hub, session, stop) == "stalled"
            except Exception as e:
                log("session crash", type(e).__name__, e)
            finally:
                try:
                    graceful_close(*session)
                except Exception:
                    pass
                session = None
                hub.drop_all()   # 让客户端收到 EOF，触发 App 重连提示
                if stalled:
                    log("reset to PTP config for re-activation")
                    try:
                        d0 = Q.find_retry(3, 0.2)
                        if d0 is not None:
                            d0.set_configuration(3)
                    except Exception:
                        pass
                    time.sleep(0.5)
            if stop.is_set():
                break
            time.sleep(2)
    finally:
        stop_hid()
        with hub.lock:
            for c in hub.clients:
                try: c.close()
                except Exception: pass
        for p in (SOCK, PIDF):
            try: os.unlink(p)
            except Exception: pass
        log("resident exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
