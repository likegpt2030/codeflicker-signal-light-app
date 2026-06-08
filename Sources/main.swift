import AppKit
import Foundation

// MARK: - SSE Client (streaming via URLSessionDataDelegate)

class SSEClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var onData: ((String) -> Void)?
    private var buffer = ""
    private var urlString: String = ""

    func connect(url: String, onData: @escaping (String) -> Void) {
        self.onData = onData
        self.urlString = url
        guard let url = URL(string: url) else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        task = session?.dataTask(with: request)
        task?.resume()
    }

    func disconnect() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        buffer += text

        while let range = buffer.range(of: "\n\n") {
            let chunk = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            for line in chunk.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let jsonStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let handler = onData {
                        handler(jsonStr)
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let url = urlString
        let handler = onData
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let handler {
                self?.connect(url: url, onData: handler)
            }
        }
    }
}

// MARK: - CF Process Monitor

class CFProcessMonitor {
    private var timer: Timer?
    private var wasRunning = false
    var onCFStart: (() -> Void)?
    var onCFExit: (() -> Void)?
    private let pidFilePath: String

    init() {
        pidFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".codeflicker/signal-light-sim/.cf-active")
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkCFProcess()
        }
        timer?.tolerance = 0.3
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkCFProcess() {
        // PID file must be recent (< 20s old) to be valid
        // This handles stale files if log-watcher exits unexpectedly
        let isRunning: Bool = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: pidFilePath),
                  let mtime = attrs[.modificationDate] as? Date else {
                return false
            }
            return Date().timeIntervalSince(mtime) < 20
        }()

        if isRunning && !wasRunning {
            onCFStart?()
        } else if !isRunning && wasRunning {
            onCFExit?()
        }
        wasRunning = isRunning
    }
}

// MARK: - Traffic Light View

class TrafficLightView: NSView {
    enum LightState {
        case idle           // green solid
        case thinking       // yellow breathing
        case working        // yellow breathing
        case tool_done      // yellow breathing
        case attention      // yellow flashing
        case permission     // yellow fast flashing
        case blocked        // red flashing
        case done           // green flashing
        case session_start  // green solid
        case session_end    // green solid
        case waiting        // dim yellow pulse — waiting for cf
    }

    var state: LightState = .waiting {
        didSet { needsDisplay = true; updateAnimation() }
    }

    private var timerSource: DispatchSourceTimer?
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    let lightRadius: CGFloat = 18
    let lightSpacing: CGFloat = 10
    let housingPadding: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAnimation()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = CACurrentMediaTime() - startTime

        let (r, y, g) = computeLightValues(t: t)

        let w = bounds.width
        let h = bounds.height
        let housingW = housingPadding * 2 + lightRadius * 2
        let housingH = housingPadding * 2 + lightRadius * 2 * 3 + lightSpacing * 2
        let hx = (w - housingW) / 2
        let hy = (h - housingH) / 2

        // Housing background
        let housingPath = NSBezierPath(roundedRect: NSRect(x: hx, y: hy, width: housingW, height: housingH), xRadius: 16, yRadius: 16)
        NSColor(white: 0.1, alpha: 1.0).setFill()
        housingPath.fill()

        // Housing border
        NSColor(white: 0.22, alpha: 0.6).setStroke()
        housingPath.lineWidth = 1.0
        housingPath.stroke()

        // Light positions (bottom to top: green, yellow, red)
        let centerX = w / 2
        let greenY = hy + housingPadding + lightRadius
        let yellowY = greenY + lightRadius * 2 + lightSpacing
        let redY = yellowY + lightRadius * 2 + lightSpacing

        drawLight(ctx: ctx, center: CGPoint(x: centerX, y: redY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0), intensity: r)
        drawLight(ctx: ctx, center: CGPoint(x: centerX, y: yellowY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.03, alpha: 1.0), intensity: y)
        drawLight(ctx: ctx, center: CGPoint(x: centerX, y: greenY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.30, alpha: 1.0), intensity: g)
    }

    private func drawLight(ctx: CGContext, center: CGPoint, radius: CGFloat, onColor: NSColor, intensity: CGFloat) {
        let r = radius

        // Outer glow when bright
        if intensity > 0.3 {
            let glowR = r + 6 * intensity
            let glowColor = onColor.withAlphaComponent(intensity * 0.25)
            ctx.setFillColor(glowColor.cgColor)
            ctx.fillEllipse(in: NSRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2))
        }

        // Bezel ring
        let bezelColor = NSColor(white: 0.06, alpha: 1.0)
        ctx.setFillColor(bezelColor.cgColor)
        ctx.fillEllipse(in: NSRect(x: center.x - r - 2, y: center.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))

        // Light bulb
        let onR = onColor.redComponent, onG = onColor.greenComponent, onB = onColor.blueComponent
        let off: CGFloat = 0.06
        let curR = off + (onR - off) * intensity
        let curG = off + (onG - off) * intensity
        let curB = off + (onB - off) * intensity
        ctx.setFillColor(CGColor(red: curR, green: curG, blue: curB, alpha: 1.0))
        ctx.fillEllipse(in: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    private func computeLightValues(t: TimeInterval) -> (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, y: CGFloat = 0, g: CGFloat = 0
        switch state {
        case .idle, .session_start, .session_end:
            g = 0.9; r = 0; y = 0
        case .thinking, .working, .tool_done:
            let breath = 0.2 + 0.7 * (0.5 + 0.5 * sin(t * 2.5))
            y = breath; r = 0; g = 0
        case .attention:
            let flash = (Int(t * 2) % 2 == 0) ? 0.9 : 0.06
            y = CGFloat(flash); r = 0; g = 0
        case .permission:
            let flash = (Int(t * 6) % 2 == 0) ? 0.9 : 0.06
            y = CGFloat(flash); r = 0; g = 0
        case .blocked:
            let flash = (Int(t * 4) % 2 == 0) ? 0.9 : 0.06
            r = CGFloat(flash); y = 0; g = 0
        case .done:
            let flash = (Int(t * 2) % 2 == 0) ? 0.9 : 0.06
            g = CGFloat(flash); r = 0; y = 0
        case .waiting:
            let pulse = 0.05 + 0.15 * (0.5 + 0.5 * sin(t * 1.2))
            y = pulse; r = 0; g = 0
        }
        return (r, y, g)
    }

    private func updateAnimation() {
        switch state {
        case .idle, .session_start, .session_end:
            stopTimer()
            needsDisplay = true
        case .thinking, .working, .tool_done, .waiting:
            startTimer()
        case .attention, .permission, .blocked, .done:
            startTimer()
        }
    }

    private func startTimer() {
        guard timerSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        source.setEventHandler { [weak self] in
            self?.needsDisplay = true
        }
        source.resume()
        timerSource = source
    }

    private func stopTimer() {
        timerSource?.cancel()
        timerSource = nil
    }
}

// MARK: - Signal Mapping

func signalToState(_ signal: String) -> TrafficLightView.LightState {
    switch signal {
    case "idle":          return .idle
    case "thinking":      return .thinking
    case "working":       return .working
    case "tool_done":     return .tool_done
    case "attention":     return .attention
    case "permission":    return .permission
    case "blocked":      return .blocked
    case "done":          return .done
    case "session_start": return .session_start
    case "session_end":   return .session_end
    default:              return .attention
    }
}

// MARK: - Backend Process Manager

class BackendManager {
    private var serverProcess: Process?
    private var watcherProcess: Process?

    func start() {
        let simDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codeflicker/signal-light-sim")

        serverProcess = launchProcess(executable: "/usr/local/bin/node", arguments: [simDir + "/server.js"], workDir: simDir)
        sleep(1)
        watcherProcess = launchProcess(executable: "/usr/local/bin/node", arguments: [simDir + "/log-watcher.js"], workDir: simDir)
    }

    func stop() {
        serverProcess?.terminate()
        watcherProcess?.terminate()
        serverProcess = nil
        watcherProcess = nil
    }

    private func launchProcess(executable: String, arguments: [String], workDir: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let devnull = FileHandle(forUpdatingAtPath: "/dev/null")!
        p.standardOutput = devnull
        p.standardError = devnull
        try? p.run()
        return p
    }
}

// MARK: - Floating Panel

class FloatingPanel: NSPanel {
    var trafficLight: TrafficLightView!
    private var sseClient = SSEClient()
    var statusField: NSTextField!

    init() {
        let lightR: CGFloat = 18
        let hp: CGFloat = 14
        let ls: CGFloat = 10
        let housingW = hp * 2 + lightR * 2 + 4
        let housingH = hp * 2 + lightR * 2 * 3 + ls * 2 + 4
        let viewW = housingW + 24
        let viewH = housingH + 56

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: viewW, height: viewH),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        backgroundColor = NSColor(white: 0.05, alpha: 0.85)
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        // Traffic light view
        let lightFrameH = housingH + 4
        trafficLight = TrafficLightView(frame: NSRect(x: 0, y: 30, width: viewW, height: lightFrameH))
        trafficLight.state = .waiting
        contentView?.addSubview(trafficLight)

        // Status text
        statusField = NSTextField(labelWithString: "等待 cf 启动…")
        statusField.alignment = .center
        statusField.textColor = NSColor(white: 0.55, alpha: 1.0)
        statusField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusField.frame = NSRect(x: 0, y: 8, width: viewW, height: 18)
        contentView?.addSubview(statusField)

        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - viewW - 20
            let y = screenFrame.maxY - viewH - 20
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        alphaValue = 0
        connectSSE()
    }

    func showAnimated() {
        setIsVisible(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            self.animator().alphaValue = 1.0
        }
    }

    func hideAnimated() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            self.animator().alphaValue = 0.0
        } completionHandler: {
            self.setIsVisible(false)
        }
    }

    private func connectSSE() {
        sseClient.connect(url: "http://127.0.0.1:9876/events") { [weak self] jsonStr in
            guard let self else { return }
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let signal = json["signal"] as? String ?? "idle"
                let summary = json["summary"] as? String ?? ""
                DispatchQueue.main.async {
                    self.trafficLight.state = signalToState(signal)
                    self.statusField.stringValue = summary
                }
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    let backend = BackendManager()
    let monitor = CFProcessMonitor()
    var cfRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        backend.start()

        panel = FloatingPanel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Signal Light")
            button.image?.size = NSSize(width: 16, height: 16)
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示信号灯", action: #selector(showPanel), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Start monitoring cf process
        monitor.onCFStart = { [weak self] in
            guard let self else { return }
            self.cfRunning = true
            self.panel.trafficLight.state = .idle
            self.panel.statusField.stringValue = "空闲"
            self.panel.showAnimated()
        }

        monitor.onCFExit = { [weak self] in
            guard let self else { return }
            self.cfRunning = false
            self.panel.trafficLight.state = .waiting
            self.panel.statusField.stringValue = "等待 cf 启动…"
            self.panel.hideAnimated()
        }

        monitor.start()

        // Check initial state — if cf is already running, show panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.cfRunning == true {
                self?.panel.showAnimated()
            }
        }
    }

    @MainActor @objc func showPanel() {
        panel.showAnimated()
    }

    @MainActor @objc func quit() {
        monitor.stop()
        backend.stop()
        NSApp.terminate(nil)
    }

    // Never let SignalLight become the frontmost app
    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.hide(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
