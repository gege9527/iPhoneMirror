# 协议笔记

投屏走 QuickTime USB 协议（非 CoreMediaIO），HID 走 CoreDevice userspace 隧道。

## 激活

设备默认在 usbmux 配置（3）。发送控制请求后设备重枚举，出现第 7 个配置：

```
ctrl(0x40, 0x52, 0x0000, 0x0002)
```

新配置 `PTP + Apple Mobile Device + Valeria` 中，interface `class=0xFF / subclass=0x2A`
即视频接口（iPhone 12 Pro：IN `0x86` / OUT `0x05`，512 字节 bulk）。

## 消息

小端 uint32 长度 + 4 字节 magic + 内容。

| 消息 | magic | 处理 |
|---|---|---|
| PING | `gnip` | 原样回写，随后主动发 HPD1 |
| SYNC CWPA | `cnys` + `apwc` | RPLY + 本地 clockRef |
| SYNC AFMT | — | RPLY + `{"Error": 0}` |
| SYNC CVRP | — | RPLY + HPD1 + NEED；SPS/PPS 从 avcC 提取 |
| SYNC CLOK / TIME / STOP | — | 对应 RPLY（CMTime 24 字节） |
| ASYN FEED | `nysa` + `deep` | TLV 遍历取 `sdat`，AVCC 转 Annex-B |

常用常量：`dict`、`keyv`、`strk`、`vlub`、`vbmn`、`sdat`、`sbuf`。

## 握手时序

1. `ctrl(0x40,0x52,0,2)` → 配置 6 → 7
2. `set_configuration(7)` → `claim_interface(2)`
3. 读 `0x86` 收到 PING → 原样回写
4. 等 50ms → 主动发 ASYN HPD1（`Valeria`、`HEVCDecoderSupports444`、`DisplaySize`）
5. 收 SYNC CVRP → 回 RPLY → 30ms → 再发 HPD1 → 30ms → 发 NEED
6. 收 ASYN FEED → TLV 取 `sdat` → 转 Annex-B

**必须走 TLV 遍历解析 sbuf**：数据里会出现假的 `sdat` magic，用 `find()`
会在第二帧后错位。

## 实测数据

- 888×1920，约 29-30 fps，约 1.4 Mbps
- 延迟约 100ms

## 坑

- 设备端 AV 会话残留时配置 7 仍在但不推流；切回配置 3 再重新激活即可恢复，
  不需要拔线（早期结论有误）
- 切换 USB 配置会断开 HID 隧道，必须等视频就绪再建隧道
- macOS IOKit 独占整设备：libusb 打开后第二个句柄无法 claim usbmux 接口
