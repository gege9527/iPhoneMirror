import Cocoa
import AVFoundation
import VideoToolbox
import IOKit
import IOKit.usb

/// 用 IOKit 检测 iPhone 是否插着（VID 0x05AC / PID 0x12A8）
func isIPhoneConnected() -> Bool {
    guard let matching = IOServiceMatching("IOUSBHostDevice") else { return false }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        let vid = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)
        let pid = IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0)
        let v = (vid?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
        let p = (pid?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
        IOObjectRelease(service)
        if v == 0x05AC && p == 0x12A8 { return true }
        service = IOIteratorNext(iterator)
    }
    return false
}

/// 读 iPhone 当前 USB 配置号（QT config 是 7）
func usbConfigurationValue() -> Int {
    guard let matching = IOServiceMatching("IOUSBHostDevice") else { return -1 }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == KERN_SUCCESS else { return -1 }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        let vid = (IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
        let pid = (IORegistryEntryCreateCFProperty(service, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
        if vid == 0x05AC && pid == 0x12A8 {
            let cfg = (IORegistryEntryCreateCFProperty(service, "bConfigurationValue" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
            IOObjectRelease(service)
            return cfg
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return -1
}

// 把鼠标事件 -> 归一化坐标(0..65535) 写入 FIFO，供采集进程转成 HID 注入
final class InputSink {
    let path: String
    private var fh: FileHandle?
    private let lock = NSLock()

    init(path: String) {
        self.path = path
        if !FileManager.default.fileExists(atPath: path) {
            mkfifo(path, 0o600)
        }
        // 关键：不能用 FileHandle(forWritingAtPath:) 打开 FIFO —— 没有读端时它会永久阻塞，
        // 之前在 main 线程调用直接把整个 App 挂起（hang 报告 fifo_open -> lck_mtx_sleep）
    }

    private func ensureOpen() {
        guard fh == nil else { return }
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }   // 还没有读端，下次再试
        fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func send(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        ensureOpen()
        guard let h = fh else { return }
        h.write((line + "\n").data(using: .utf8)!)
    }
}

final class VideoView: NSView {
    let display = AVSampleBufferDisplayLayer()
    var sink: InputSink?
    var videoSize = CGSize(width: 888, height: 1920)
    var onVideoSizeChanged: ((CGSize) -> Void)?
    var landscape: Bool = false   // 用户期望的显示方向
    let statusLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.textColor = .secondaryLabelColor
        l.font = NSFont.systemFont(ofSize: 13)
        l.alignment = .center
        l.isHidden = true
        return l
    }()

    /// 断开时清空画面（否则最后一帧会一直停在那里）
    func clearVideo() {
        display.flush()          // 清掉待显示队列与最后一帧
        display.isHidden = true
    }

    func resumeVideo() {
        display.isHidden = false
    }

    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        statusLabel.sizeToFit()
        statusLabel.frame.origin = CGPoint(x: (bounds.width - statusLabel.frame.width) / 2,
                                           y: bounds.midY)
    }

    func applyOrientation() {
        // transform 作用于 layer 的 bounds/position，frame 会被 transform 扭曲，这里必须用 bounds
        let streamLandscape = videoSize.width > videoSize.height
        let needRotate = (landscape != streamLandscape)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needRotate {
            // 旋转后视觉尺寸 = 窗口尺寸；旋转前的 layer 尺寸要交换宽高
            display.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            display.position = CGPoint(x: bounds.midX, y: bounds.midY)
            display.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
        } else {
            display.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            display.position = CGPoint(x: bounds.midX, y: bounds.midY)
            display.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
        addSubview(statusLabel)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        applyOrientation()
    }

    // 视频实际显示矩形（aspect fit 后的居中区域）
    private func videoRect() -> CGRect {
        let b = bounds
        // 横屏时画面视觉尺寸是宽高互换的
        let vw = landscape ? videoSize.height : videoSize.width
        let vh = landscape ? videoSize.width : videoSize.height
        guard vw > 0, vh > 0 else { return b }
        let scale = min(b.width / vw, b.height / vh)
        let w = vw * scale, h = vh * scale
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    /// clampToEdge=true 时允许拖出窗口（坐标夹到边界），用于拖动/抬起
    private func normalized(_ event: NSEvent, clampToEdge: Bool = false) -> (Int, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect()
        if !clampToEdge && !r.contains(p) { return nil }
        // NSView 原点在左下，视频坐标原点在左上
        let u = min(1.0, max(0.0, (p.x - r.minX) / r.width))          // 窗口横向 0..1
        let v = min(1.0, max(0.0, 1.0 - (p.y - r.minY) / r.height))   // 窗口纵向 0..1（上=0）
        var hx: Int, hy: Int
        if landscape {
            // layer 顺时针转了 90°：窗口(u,v) -> 流坐标(lx=v, ly=1-u)
            hx = Int(v * 65535)
            hy = Int((1.0 - u) * 65535)
        } else {
            hx = Int(u * 65535)
            hy = Int(v * 65535)
        }
        return (max(0, min(65535, hx)), max(0, min(65535, hy)))
    }

    private var pressPoint: (Int, Int)?
    private var isDragging = false
    private var isLongPress = false
    private var longPressTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressPoint = normalized(event)
        isDragging = false
        isLongPress = false
        longPressTimer?.invalidate()
        // 按住不动 600ms -> 进入长按，此时才发 down（松手时由 mouseUp 发 up）
        guard let p = pressPoint else { return }
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self = self, !self.isDragging, !self.isLongPress else { return }
            self.isLongPress = true
            self.sink?.send("down \(p.0) \(p.1)")
        }
    }
    private var lastMoveSent: CFTimeInterval = 0

    override func mouseDragged(with event: NSEvent) {
        longPressTimer?.invalidate()     // 一动就算拖动，取消长按计时
        guard let start = pressPoint else { return }
        if !isDragging && !isLongPress {
            isDragging = true
            lastMoveSent = 0
            sink?.send("down \(start.0) \(start.1)")
        }
        // 8ms 节流：拖得太快时丢中间点，USB 不会被灌满
        let now = CACurrentMediaTime()
        guard now - lastMoveSent >= 0.008 else { return }
        lastMoveSent = now
        if let (x, y) = normalized(event, clampToEdge: true) {
            sink?.send("move \(x) \(y)")
        }
    }
    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        defer {
            pressPoint = nil
            isDragging = false
            isLongPress = false
        }
        if isDragging || isLongPress {
            // 拖动结束 或 长按结束 —— 统一发 up
            if let (x, y) = normalized(event, clampToEdge: true) {
                sink?.send("up \(x) \(y)")
            } else if let p = pressPoint {
                sink?.send("up \(p.0) \(p.1)")
            }
        } else if let start = pressPoint {
            // 600ms 内松手：纯点击，原子操作
            sink?.send("click \(start.0) \(start.1)")
        }
    }
    override func scrollWheel(with event: NSEvent) {
        sink?.send("scroll \(Int(event.scrollingDeltaY))")
    }
    // macOS keyCode -> USB HID Keyboard usage
    private static let hidMap: [UInt16: UInt8] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D, 7: 0x1B,
        8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15,
        16: 0x1C, 17: 0x17, 18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23,
        23: 0x22, 25: 0x26, 26: 0x24, 28: 0x25, 29: 0x27, 31: 0x12, 32: 0x18,
        34: 0x0C, 35: 0x13, 37: 0x0F, 38: 0x0D, 40: 0x0E, 45: 0x11, 46: 0x10,
        36: 0x28, 51: 0x2A, 53: 0x29, 117: 0x4C,  // return / delete / esc / forwardDelete
        123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,  // arrows
        56: 0xE1, 60: 0xE5, 58: 0xE2, 61: 0xE6, 59: 0xE0, 62: 0xE4, 55: 0xE3,
        115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E,  // home/end/pgup/pgdn
    ]

    override func keyDown(with event: NSEvent) {
        // Esc / Tab 保留为快捷键（回主屏 / 多任务）
        switch event.keyCode {
        case 53: sink?.send("home"); return
        case 48: sink?.send("switch"); return
        default: break
        }
        // 其余按键：把手按的修饰键一起发（iOS 靠这个识别 Ctrl+Space 等组合）
        var usages: [UInt8] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { usages.append(0xE0) }
        if flags.contains(.shift)   { usages.append(0xE1) }
        if flags.contains(.option)  { usages.append(0xE2) }
        if flags.contains(.command) { usages.append(0xE3) }
        if let u = VideoView.hidMap[event.keyCode] { usages.append(u) }
        else if event.keyCode == 49 { usages.append(0x2C) }   // 空格
        else if event.keyCode == 57 { usages.append(0x39) }   // Caps Lock
        guard !usages.isEmpty else { return }
        sink?.send("key " + usages.map { String($0) }.joined(separator: ","))
    }
}

// 顶部工具栏：返回 / Home / 多任务
final class Toolbar: NSView {
    var sink: InputSink?
    var onRotate: (() -> Void)?
    var onPin: (() -> Void)?
    var onReset: (() -> Void)?
    var isLandscape = false
    var isPinned = true
    private var buttons: [NSButton] = []
    private var alphaSlider: NSSlider?
    private var moreButton: NSButton?
    private var itemsSpec: [(String, String, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).cgColor

        let items: [(String, String, String)] = [
            ("house", "主屏", "home"),
            ("rectangle.on.rectangle", "多任务", "switch"),
            ("speaker.plus", "音量+", "volume_up"),
            ("speaker.minus", "音量-", "volume_down"),
            ("speaker.slash", "静音", "mute"),
            ("power", "电源", "lock"),
            ("mic", "Siri", "siri"),
            ("doc.on.doc", "粘贴", "paste"),
            ("pin", "置顶", "pin"),
        ]
        itemsSpec = items
        // 窄窗口时的「...」折叠菜单按钮
        let mb = NSButton(title: "⋯", target: self, action: #selector(showMenu(_:)))
        mb.bezelStyle = .rounded
        mb.isBordered = false
        mb.font = NSFont.systemFont(ofSize: 16)
        mb.toolTip = "更多操作"
        mb.isHidden = true
        addSubview(mb)
        moreButton = mb

        let bw: CGFloat = 38
        for (i, item) in items.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(onTap(_:)))
            b.bezelStyle = .rounded
            b.isBordered = false
            b.identifier = NSUserInterfaceItemIdentifier(item.2)
            b.toolTip = item.1
            if #available(macOS 11.0, *) {
                b.image = NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)
            } else {
                b.title = item.1
            }
            if item.2 == "pin" {
                b.contentTintColor = isPinned ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            }
            b.frame = NSRect(x: 6 + CGFloat(i) * (bw + 3), y: 6, width: bw, height: 32)
            addSubview(b)
            buttons.append(b)
        }

        // 透明度滑块
        let sliderX = 6 + CGFloat(items.count) * (bw + 3) + 6
        let s = NSSlider(value: 1.0, minValue: 0.25, maxValue: 1.0,
                         target: self, action: #selector(onAlpha(_:)))
        s.frame = NSRect(x: sliderX, y: 6, width: 70, height: 32)
        s.toolTip = "窗口透明度"
        s.controlSize = .small
        addSubview(s)
        alphaSlider = s
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 窄窗口时全部收进「⋯」菜单，避免按钮被裁切
        let narrow = bounds.width < 300
        moreButton?.isHidden = !narrow
        moreButton?.frame = NSRect(x: 6, y: 6, width: 36, height: 32)
        for b in buttons { b.isHidden = narrow }
        alphaSlider?.isHidden = narrow || bounds.width < 420
        if narrow { return }

        let n = CGFloat(buttons.count)
        let sliderW: CGFloat = 70
        let avail = max(bounds.width - 12 - sliderW - 8, 100)
        let bw = max(20, min(38, avail / max(n, 1) - 3))
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: 6 + CGFloat(i) * (bw + 3), y: 6, width: bw, height: 32)
        }
        alphaSlider?.frame = NSRect(x: 6 + n * (bw + 3) + 6, y: 6, width: sliderW, height: 32)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for item in itemsSpec {
            let mi = NSMenuItem(title: item.1, action: #selector(menuAction(_:)), keyEquivalent: "")
            mi.representedObject = item.2
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let pin = NSMenuItem(title: isPinned ? "取消置顶" : "置顶",
                             action: #selector(menuAction(_:)), keyEquivalent: "")
        pin.representedObject = "pin"
        pin.target = self
        menu.addItem(pin)

        // 透明度子菜单
        let alphaMenu = NSMenu()
        let cur = window?.alphaValue ?? 1.0
        for pct in [100, 85, 70, 55, 40, 25] {
            let v = CGFloat(pct) / 100.0
            let mi = NSMenuItem(title: "\(pct)%", action: #selector(menuAlpha(_:)), keyEquivalent: "")
            mi.representedObject = Double(v)
            mi.target = self
            mi.state = abs(cur - v) < 0.02 ? .on : .off
            alphaMenu.addItem(mi)
        }
        let alphaItem = NSMenuItem(title: "窗口透明度", action: nil, keyEquivalent: "")
        alphaItem.submenu = alphaMenu
        menu.addItem(alphaItem)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func menuAlpha(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        window?.alphaValue = CGFloat(v)
        alphaSlider?.doubleValue = v
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        if cmd == "pin" { isPinned.toggle(); onPin?(); return }
        if cmd == "reset" { onReset?(); return }
        sink?.send(cmd)
    }

    @objc private func onAlpha(_ sender: NSSlider) {
        window?.alphaValue = CGFloat(sender.doubleValue)
    }

    @objc private func onTap(_ sender: NSButton) {
        guard let cmd = sender.identifier?.rawValue else { return }
        if cmd == "pin" {
            isPinned.toggle()
            onPin?()
            sender.contentTintColor = isPinned ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            return
        }
        if cmd == "rotate" {
            // 只负责向设备请求目标方向；画面/窗口由状态文件自动跟随
            sink?.send(isLandscape ? "portrait" : "landscape")
            isLandscape.toggle()
            return
        }
        sink?.send(cmd)
        NSSound.beep()
    }
}

final class RootView: NSView {
    let toolbar = Toolbar()
    let video = VideoView()
    let barHeight: CGFloat = 44

    func toggleLandscape() {
        video.landscape.toggle()
        video.applyOrientation()
        applyWindowSize(animated: true)
    }

    func applyWindowSize(animated: Bool) {
        guard let win = self.window else { return }
        let bar: CGFloat = barHeight
        let ratio = video.videoSize.width / video.videoSize.height   // 流的宽高比
        let shortSide: CGFloat = 420
        var w: CGFloat, h: CGFloat
        if video.landscape {
            h = bar + shortSide
            w = shortSide * max(ratio, 1 / ratio)
            if ratio < 1 { w = shortSide * (1 / ratio) } else { w = shortSide * ratio }
        } else {
            w = shortSide
            h = bar + shortSide / min(ratio, 1 / ratio) * 1
            h = bar + (shortSide * (ratio >= 1 ? ratio : 1 / ratio))
        }
        var f = win.frame
        f.origin.y += f.size.height - h
        f.size = NSSize(width: w, height: h)
        win.setFrame(f, display: true, animate: animated)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
        addSubview(video)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        video.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
    }
}

func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMFormatDescription? {
    var fmt: CMFormatDescription?
    sps.withUnsafeBufferPointer { sp in
        pps.withUnsafeBufferPointer { pp in
            var ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
            var sizes: [Int] = [sps.count, pps.count]
            _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
    }
    return fmt
}

func enqueue(nal: [UInt8], fmt: CMFormatDescription, layer: AVSampleBufferDisplayLayer) {
    var len = UInt32(nal.count).bigEndian
    var payload = Data(bytes: &len, count: 4)
    payload.append(contentsOf: nal)
    var bb: CMBlockBuffer?
    let st = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &bb)
    guard st == kCMBlockBufferNoErr, let block = bb else { return }
    payload.withUnsafeBytes { raw in
        _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
    }
    var sb: CMSampleBuffer?
    var size = payload.count
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                    decodeTimeStamp: .invalid)
    CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sb)
    if let s = sb {
        if layer.status == .failed { layer.flush() }
        layer.enqueue(s)
    }
}

final class Parser {
    var buf = Data()
    var fmt: CMFormatDescription?
    var sps: [UInt8] = []
    var pps: [UInt8] = []
    weak var layer: AVSampleBufferDisplayLayer?
    weak var view: VideoView?
    var onResize: ((CGSize) -> Void)?

    func feed(_ d: Data) {
        buf.append(d)
        let bytes = [UInt8](buf)
        var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                starts.append(i); i += 4
            } else if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
                starts.append(i); i += 3
            } else { i += 1 }
        }
        guard starts.count >= 2 else { return }
        let cut = starts[starts.count - 1]
        for k in 0..<(starts.count - 1) {
            let s = starts[k], e = starts[k+1]
            let hdr = (s + 3 < bytes.count && bytes[s+3] == 1) ? 4 : 3
            if s + hdr >= e { continue }
            dispatch(Array(bytes[(s+hdr)..<e]))
        }
        buf.removeFirst(cut)
    }

    private func dispatch(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }
        let t = nal[0] & 0x1f
        if t == 7 { sps = nal; tryBuild(); return }
        if t == 8 { pps = nal; tryBuild(); return }
        guard let f = fmt, let l = layer else { return }
        enqueue(nal: nal, fmt: f, layer: l)
    }

    private var lastW: Int32 = 0
    private var lastH: Int32 = 0

    private func tryBuild() {
        guard !sps.isEmpty, !pps.isEmpty else { return }
        guard let f = makeFormat(sps: sps, pps: pps) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(f)
        guard dims.width != lastW || dims.height != lastH else { return }
        fmt = f
        lastW = dims.width; lastH = dims.height
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        let cb = onResize
        DispatchQueue.main.async {
            self.view?.videoSize = size
            cb?(size)
            FileHandle.standardError.write("format \(dims.width)x\(dims.height)\n".data(using: .utf8)!)
        }
    }
}

// 窗口比例锁定：拖动边缘时严格保持视频比例，消除黑边
final class MirrorWindowDelegate: NSObject, NSWindowDelegate {
    var barHeight: CGFloat = 44
    var videoRatio: CGFloat = 888.0 / 1920.0    // 流宽高比
    var landscape = false

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let desired = landscape ? 1.0 / videoRatio : videoRatio   // 期望的宽/高
        var w = max(frameSize.width, 120)
        var h = barHeight + w / desired
        if frameSize.height > h + 1 {                     // 用户在拉高度
            h = max(frameSize.height, 80)
            w = (h - barHeight) * desired
            h = barHeight + w / desired
        }
        return NSSize(width: w, height: h)
    }
}

var captureProc: Process?
var hidProc: Process?
var captureActive = false

final class MirrorAppDelegate: NSObject, NSApplicationDelegate {
    // 关闭窗口即退出整个 App（连带清理采集/HID 子进程）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    // 点 Dock 图标时把窗口找回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
    // 退出时清理 Python 子进程
    func applicationWillTerminate(_ notification: Notification) {
        stopResident()   // 关 App 即释放设备，不留常驻进程
        if let p = hidProc { p.terminate() }
        if let p = captureProc { p.terminate() }
    }
}

let app = NSApplication.shared
let appDelegate = MirrorAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
let rect = NSRect(x: 120, y: 80, width: 540, height: 944)
let win = NSWindow(contentRect: rect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
win.title = "iPhone Mirror"
let sink = InputSink(path: "/tmp/iphonemirror.input")
let root = RootView(frame: rect)
root.video.sink = sink
root.toolbar.sink = sink
win.contentMinSize = NSSize(width: 120, height: 80)
root.toolbar.onPin = { [weak root] in
    // 置顶切换
    win.level = (root?.toolbar.isPinned ?? true) ? .floating : .normal
}

root.toolbar.onReset = {
    // 一键重置：请求采集进程做 USB 重枚举（等价拔插）
    guard let fh = FileHandle(forWritingAtPath: "/tmp/iphonemirror.reset") ??
                    FileHandle(forUpdatingAtPath: "/tmp/iphonemirror.reset") else {
        FileManager.default.createFile(atPath: "/tmp/iphonemirror.reset", contents: Data())
        try? "reset".write(toFile: "/tmp/iphonemirror.reset", atomically: true, encoding: .utf8)
        return
    }
    try? "reset".write(toFile: "/tmp/iphonemirror.reset", atomically: true, encoding: .utf8)
    fh.closeFile()
}

root.toolbar.onRotate = { [weak root] in
    root?.toggleLandscape()
    winDelegate.landscape = root?.video.landscape ?? false
    winDelegate.videoRatio = (root?.video.videoSize.width ?? 888) / (root?.video.videoSize.height ?? 1920)
}
let view = root.video
win.contentView = root
let winDelegate = MirrorWindowDelegate()
win.delegate = winDelegate
win.level = .floating
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let parser = Parser()
parser.onResize = { size in
    // 窗口跟随视频宽高比：短边固定 420
    let bar: CGFloat = 44
    let ratio = size.width / size.height
    let w: CGFloat = ratio >= 1 ? 760 : 420
    let h = bar + w / ratio
    var f = win.frame
    f.origin.y += f.size.height - h   // 底部对齐，避免窗口跳走
    f.size = NSSize(width: w, height: h)
    win.setFrame(f, display: true, animate: true)
}
parser.layer = view.display
parser.view = view

// ---- 子进程管理：player 自己拉起采集与 HID ----
let resDir: String = Bundle.main.resourcePath ?? (FileManager.default.currentDirectoryPath)
/// 检查解释器是否装了 usb / pymobiledevice3
func pythonHasDeps(_ path: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = ["-c", "import usb, pymobiledevice3"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    return proc.terminationStatus == 0
}

/// 选一个装了依赖的 Python：环境变量 → pyenv → Homebrew → 系统
/// 结果缓存到 /tmp，避免每次启动都探测
let pyPath: String = {
    let cache = "/tmp/iphonemirror.python"
    if let s = try? String(contentsOfFile: cache, encoding: .utf8) {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    var cands: [String] = []
    if let e = ProcessInfo.processInfo.environment["IPM_PYTHON"] { cands.append(e) }
    cands.append(NSHomeDirectory() + "/.pyenv/shims/python3")
    cands += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    for p in cands where FileManager.default.isExecutableFile(atPath: p) {
        if pythonHasDeps(p) {
            try? p.write(toFile: cache, atomically: true, encoding: .utf8)
            return p
        }
    }
    return cands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
}()

/// 读当前设备的 iOS 版本（走 pymobiledevice3 usbmux list，几百毫秒）
func currentIOSVersion() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: pyPath)
    p.arguments = ["-m", "pymobiledevice3", "usbmux", "list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let s = String(data: data, encoding: .utf8),
          let r = s.range(of: "\"ProductVersion\"\\s*:\\s*\"([0-9]+\\.[0-9.]+)\"",
                          options: .regularExpression) else { return nil }
    let matched = String(s[r])
    let parts = matched.components(separatedBy: "\"")
    return parts.count >= 4 ? parts[3] : nil
}

// ---- 常驻链路：resident.py 独占 USB 会话，App 只做 socket 客户端 ----
let residentSock = "/tmp/iphonemirror.resident.sock"
let residentLog = "/tmp/iphonemirror.resident.log"

func connectUnix(_ path: String) -> FileHandle? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= cap else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        bytes.withUnsafeBytes { dst.copyBytes(from: $0) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard rc == 0 else { close(fd); return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

/// 拉起常驻进程（脱离 App 生命周期，App 退出不会带走它）
/// 优先用打包好的自包含运行时，没有才回退到系统 Python + 脚本
func spawnResident() {
    let runtime = resDir + "/runtime/runtime_entry"
    let script = resDir + "/resident.py"
    let cmd: String
    if FileManager.default.fileExists(atPath: runtime) {
        cmd = "nohup '\(runtime)' >>'\(residentLog)' 2>&1 </dev/null &"
    } else {
        cmd = "nohup '\(pyPath)' '\(script)' >>'\(residentLog)' 2>&1 </dev/null &"
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    // macOS 没有 setsid；bash 退出后子进程由 launchd 接管，因此 App 退出不影响它
    p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch {
        FileHandle.standardError.write("resident spawn failed: \(error)\n".data(using: .utf8)!)
    }
}

/// 连接常驻流；没有常驻进程就拉起一个再连
func logLine(_ s: String) {
    let path = "/tmp/iphonemirror.player.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(s.data(using: .utf8)!); fh.closeFile()
    }
}

func mark(_ s: String) {
    logLine(String(format: "%@ %.3f\n", s, Date().timeIntervalSince1970))
}

func connectCapture() -> FileHandle? {
    if let fh = connectUnix(residentSock) { mark("reuse-resident"); return fh }
    mark("spawn-resident")
    spawnResident()
    for _ in 0..<100 {                       // 最多 25 秒（冷启动激活约 2-11 秒）
        Thread.sleep(forTimeInterval: 0.25)
        if let fh = connectUnix(residentSock) { return fh }
        if !isIPhoneConnected() { return nil }
    }
    return nil
}

func startHID() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: pyPath)
    p.arguments = [resDir + "/hid_daemon.py"]
    p.standardOutput = FileHandle(forWritingAtPath: "/tmp/iphonemirror.hid.log")
    p.standardError = p.standardOutput
    do { try p.run() } catch { return }
    hidProc = p
}

func stopChildren() {
    if let p = hidProc, p.isRunning { p.terminate() }
    hidProc = nil
}

/// App 退出时连带停掉常驻进程：设备回到普通 USB 状态（cfg 3），不留任何后台
func stopResident() {
    guard let s = try? String(contentsOfFile: "/tmp/iphonemirror.resident.pid", encoding: .utf8),
          let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    kill(pid, SIGTERM)
    // 等它把 AV 会话关干净、切回 cfg 3（最多 2 秒）
    for _ in 0..<40 {
        if kill(pid, 0) != 0 { return }
        usleep(50_000)
    }
}

// 采集循环：没有设备就不启动任何子进程
DispatchQueue.global().async {
    while true {
        if !isIPhoneConnected() {
            DispatchQueue.main.async {
                view.showStatus("未检测到 iPhone\n请用数据线连接 Mac")
                stopChildren()
            }
            Thread.sleep(forTimeInterval: 1.5)
            continue
        }
        if !captureActive {
            DispatchQueue.main.async {
                view.showStatus("正在连接 iPhone…\n请点亮屏幕（按电源键亮屏即可，锁屏界面也能采集）")
            }
            guard let fh = connectCapture() else {
                // 连不上时才查 iOS 版本（启动关键路径上不再阻塞 ~1 秒）
                if let ver = currentIOSVersion() {
                    let major = Int(ver.split(separator: ".").first ?? "0") ?? 0
                    if major < 17 {
                        DispatchQueue.main.async {
                            view.showStatus("iOS \(ver) 不支持\n需要 iOS 17 或更高版本")
                        }
                        Thread.sleep(forTimeInterval: 3.0)
                        continue
                    }
                }
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            captureActive = true
            var firstSeen = false
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                if !firstSeen {
                    firstSeen = true
                    mark("first-bytes")
                }
                DispatchQueue.main.async {
                    view.showStatus("")
                    view.resumeVideo()
                    parser.feed(d)
                }
            }
            try? fh.close()
            captureActive = false
            // 流结束（常驻进程退出/设备断开）：清屏 + 提示，稍后自动重连
            DispatchQueue.main.async {
                view.clearVideo()
                view.showStatus("设备已断开\n请检查数据线连接，插回后会自动重连")
            }
            Thread.sleep(forTimeInterval: 1.0)
        } else {
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
}

mark("app-start")
app.run()
