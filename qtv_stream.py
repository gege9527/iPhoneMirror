#!/usr/bin/env python3
"""采集 iOS 屏幕 -> stdout (Annex-B H.264)"""
import sys, time, struct, os
import usb.core, usb.util

VID, PID = 0x05ac, 0x12a8
PING=b"gnip"; SYNC=b"cnys"; ASYN=b"nysa"; RPLY=b"ylpr"
EMPTY=1; CLK1=0x7fa6c17180; CLK2=0x7fa6c17c80
DICT=b"tcid"; KEYV=b"vyek"; SKEY=b"krts"; BOOL=b"vlub"; NUM=b"vbmn"
SDAT=b"tads"; SBUF=b"fubs"

def u32(b,o): return struct.unpack_from("<I",b,o)[0]
def u64(b,o): return struct.unpack_from("<Q",b,o)[0]
def skey(k):
    kb=k.encode(); return struct.pack("<I",len(kb)+8)+SKEY+kb
def val_bool(v): return struct.pack("<I",9)+BOOL+struct.pack("<I",1 if v else 0)
def val_num(b): return struct.pack("<I",len(b)+8)+NUM+b
def num_u32(v): return struct.pack("<B",3)+struct.pack("<I",v)
def num_f64(v): return struct.pack("<B",6)+struct.pack("<d",v)
def entry(k,vb):
    sk=skey(k); return struct.pack("<I",len(sk)+len(vb)+8)+KEYV+sk+vb
def make_dict(items):
    body=b"".join(entry(k,v) for k,v in items)
    return struct.pack("<I",len(body)+8)+DICT+body
def rply_clock(c,clk): return struct.pack("<I",28)+RPLY+struct.pack("<Q",c)+struct.pack("<I",0)+struct.pack("<Q",clk)
def rply_time(c,t): return struct.pack("<I",44)+RPLY+struct.pack("<Q",c)+struct.pack("<I",0)+t
def cmtime(v,s=1000000000,f=0,e=0): return struct.pack("<QIIQ",v,s,f,e)
def asyn_dict(clk,m,d): return struct.pack("<I",20+len(d))+ASYN+struct.pack("<Q",clk)+m+d
def asyn_plain(clk,m): return struct.pack("<I",20)+ASYN+struct.pack("<Q",clk)+m
def find(): return usb.core.find(idVendor=VID, idProduct=PID)

def find_retry(n=20, delay=0.35):
    for _ in range(n):
        d = find()
        if d is not None:
            try:
                d.get_active_configuration()
                return d
            except Exception:
                pass
        time.sleep(delay)
    return None

def set_cfg_safe(dev, cfg, retries=8):
    """set_configuration 会触发设备重枚举，句柄失效，必须重新 find 后重试"""
    for _ in range(retries):
        try:
            dev.set_configuration(cfg)
            return True
        except usb.core.USBError:
            time.sleep(0.4)
            dev2 = find_retry(5)
            if dev2 is None:
                return False
            dev = dev2
    return False

def parse_sbuf(b):
    if len(b)<8: return None
    ln=u32(b,0)
    if b[4:8]!=SBUF: return None
    end=min(ln,len(b)); i=8
    while i+8<=end:
        l=u32(b,i); mg=b[i+4:i+8]
        if l<8 or i+l>end: break
        if mg==SDAT: return b[i+8:i+l]
        i+=l
    return None

def avcc_to_annexb(d):
    out=bytearray(); i=0
    while i+4<=len(d):
        ln=int.from_bytes(d[i:i+4],'big')
        if ln<=0 or i+4+ln>len(d): break
        out+=b"\x00\x00\x00\x01"+d[i+4:i+4+ln]; i+=4+ln
    return bytes(out)

def extract_ps(cvrp):
    pos=-1
    for i in range(len(cvrp)-16):
        if cvrp[i]==0x01 and cvrp[i+4] in (0xff,0xfe) and cvrp[i+5] in (0xe0,0xe1):
            pos=i; break
    if pos<0: return b""
    p=pos+5; n=cvrp[p]&0x1f; p+=1; out=b""
    for _ in range(n):
        ln=struct.unpack(">H",cvrp[p:p+2])[0]; p+=2
        out+=b"\x00\x00\x00\x01"+cvrp[p:p+ln]; p+=ln
    np=cvrp[p]; p+=1
    for _ in range(np):
        ln=struct.unpack(">H",cvrp[p:p+2])[0]; p+=2
        out+=b"\x00\x00\x00\x01"+cvrp[p:p+ln]; p+=ln
    return out

def scan(d):
    out={}
    for cfg in d:
        for intf in cfg:
            if intf.bInterfaceClass==0xff and intf.bInterfaceSubClass==0x2a:
                ein=eout=None
                for ep in intf:
                    if ep.bEndpointAddress&0x80: ein=ep.bEndpointAddress
                    else: eout=ep.bEndpointAddress
                out[cfg.bConfigurationValue]=(intf.bInterfaceNumber,ein,eout)
    return out

RESET_FILE = "/tmp/iphonemirror.reset"

def quick_attach():
    """快速路径：设备已经在 QT config(7) 时直接 claim，省掉 4-5 秒的激活流程"""
    d = find_retry(4, 0.15)
    if d is None: return None
    try:
        cur = d.get_active_configuration().bConfigurationValue
    except Exception:
        return None
    if cur != 7: return None
    info = scan(d)
    if not info: return None
    cfgv = sorted(info)[-1]; ifn, ein, eout = info[cfgv]
    for attempt in (0, 1):
        try:
            usb.util.claim_interface(d, ifn)
            print("quick attach OK (already cfg 7)", file=sys.stderr)
            return d, ifn, ein, eout
        except Exception:
            if attempt: return None
            try: d.detach_kernel_driver(ifn)
            except Exception: pass
            time.sleep(0.2)
    return None

def open_session():
    q = quick_attach()
    if q is not None:
        return q
    d=find_retry()
    if d is None: print("no device", file=sys.stderr); return None
    set_cfg_safe(d, 3)
    time.sleep(0.4)
    d=find_retry()
    if d is None: print("device lost after reset", file=sys.stderr); return None
    try: d.ctrl_transfer(0x40,0x52,0,2,0,3000)
    except Exception as e: print("ctrl", e, file=sys.stderr)
    # 原来硬等 3.5 秒，改成轮询：config 7 一出现立刻继续（通常 1-1.5 秒）
    for _ in range(20):
        d = find_retry(2, 0.2)
        if d is not None and scan(d):
            break
        time.sleep(0.2)
    d=find_retry(); info=scan(d)
    # 激活可能失败（设备端 AV 服务没起来），重试两次
    tries = 0
    while not info and tries < 2:
        tries += 1
        print(f"QT config missing, re-activate (try {tries})", file=sys.stderr)
        try:
            d.ctrl_transfer(0x40, 0x52, 0, 2, 0, 3000)
        except Exception:
            pass
        time.sleep(4)
        d = find_retry(); info = scan(d)
    if not info: print("no QT config", file=sys.stderr); return None
    cfgv=sorted(info)[-1]; ifn,ein,eout=info[cfgv]
    set_cfg_safe(d, cfgv)
    time.sleep(0.25)          # 切换后只需很短稳定时间
    d=find_retry()
    for attempt in (0,1):
        try:
            usb.util.claim_interface(d,ifn); break
        except Exception:
            if attempt: return None
            try: d.detach_kernel_driver(ifn)
            except Exception: pass
            time.sleep(0.3)
    try:
        for m in (b"0dph", b"0aph"):
            d.write(eout, asyn_plain(EMPTY, m), timeout=800)
        time.sleep(0.3)
    except Exception as e:
        print("cleanup", e, file=sys.stderr)
    return d, ifn, ein, eout

def main():
    secs=int(sys.argv[1]) if len(sys.argv)>1 else 60
    sess = open_session()
    if sess is None: return 1
    d, ifn, ein, eout = sess

    # 退出时正常关闭 AV 会话（否则设备端会残留"录制中"，下次连不上）
    import signal as _signal
    def _graceful(signum, frame):
        try:
            for m in (b"0dph", b"0aph"):
                d.write(eout, asyn_plain(EMPTY, m), timeout=500)
            time.sleep(0.15)
            usb.util.release_interface(d, ifn)
            # 故意不切回 config 3：保持 QT 配置能让下次启动走 quick_attach（1-2 秒）
            # 只清理接口占用，设备拔出后配置会自然复位
        except Exception:
            pass
        sys.exit(0)
    _signal.signal(_signal.SIGTERM, _graceful)
    _signal.signal(_signal.SIGINT, _graceful)

    out=sys.stdout.buffer
    t0=time.time(); frames=0; need=None; pinged=0; last_ps=b""; idle=0
    try:
        while time.time()-t0<secs:
            try:
                b=bytes(d.read(ein, 262144, timeout=1500))
            except usb.core.USBTimeoutError:
                idle += 1
                if idle >= 6:                       # 约 9 秒没收到任何数据 -> 认为设备已断开
                    print(f"no data for {idle} timeouts, exiting", file=sys.stderr)
                    break
                continue
            except usb.core.USBError as e:
                print("usb", e, file=sys.stderr); break
            idle = 0
            if len(b)<8: continue
            m=b[4:8]
            if m==PING:
                d.write(eout,b,timeout=800); pinged+=1
                if pinged==1:
                    time.sleep(0.05)
                    dd=make_dict([("Valeria",val_bool(True)),("HEVCDecoderSupports444",val_bool(True)),
                                  ("DisplaySize",make_dict([("Width",val_num(num_f64(1920.0))),("Height",val_num(num_f64(1200.0)))]))])
                    d.write(eout, asyn_dict(EMPTY,b"1dph",dd), timeout=800)
                continue
            if m==SYNC:
                sub=b[16:20]; corr=u64(b,20); name=sub[::-1].decode('latin1')
                if name=="cwpa": d.write(eout,rply_clock(corr,CLK1),timeout=800)
                elif name=="afmt":
                    dd=make_dict([("Error",val_num(num_u32(0)))])
                    d.write(eout, struct.pack("<I",20+len(dd))+RPLY+struct.pack("<Q",corr)+struct.pack("<I",0)+dd, timeout=800)
                elif name=="cvrp":
                    dv=u64(b,28); ps=extract_ps(b)
                    d.write(eout,rply_clock(corr,CLK2),timeout=800)
                    time.sleep(0.03)
                    dd=make_dict([("Valeria",val_bool(True)),("HEVCDecoderSupports444",val_bool(True)),
                                  ("DisplaySize",make_dict([("Width",val_num(num_f64(1920.0))),("Height",val_num(num_f64(1200.0)))]))])
                    d.write(eout, asyn_dict(EMPTY,b"1dph",dd), timeout=800)
                    need=asyn_plain(dv,b"deen"); time.sleep(0.03)
                    d.write(eout,need,timeout=800)
                    if ps and ps != last_ps:
                        out.write(ps); out.flush(); last_ps = ps
                elif name=="clok": d.write(eout,rply_clock(corr,CLK2),timeout=800)
                elif name=="time": d.write(eout,rply_time(corr,cmtime(time.time_ns())),timeout=800)
                elif name=="stop": d.write(eout,rply_clock(corr,0),timeout=800)
                else: d.write(eout,rply_clock(corr,CLK1),timeout=800)
                continue
            if m==ASYN:
                name=b[16:20][::-1].decode('latin1')
                if name=="feed":
                    nalu=parse_sbuf(b[20:])
                    if nalu:
                        try:
                            out.write(avcc_to_annexb(nalu)); out.flush(); frames+=1
                        except (BrokenPipeError, OSError): break
                    if need: d.write(eout,need,timeout=800)
                continue
    finally:
        print(f"frames={frames}", file=sys.stderr)
    return 0

if __name__=="__main__": sys.exit(main())
