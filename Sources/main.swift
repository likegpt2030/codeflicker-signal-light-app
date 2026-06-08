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

// MARK: - Status Bar Traffic Light View

class StatusBarLightView: NSView {
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

    let lightRadius: CGFloat = 5
    let lightSpacing: CGFloat = 4

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

        let h = bounds.height
        let centerY = h / 2
        let totalW = lightRadius * 2 * 3 + lightSpacing * 2
        let startX = (bounds.width - totalW) / 2 + lightRadius

        // Horizontal: red, yellow, green
        drawLight(ctx: ctx, center: CGPoint(x: startX, y: centerY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0), intensity: r)
        drawLight(ctx: ctx, center: CGPoint(x: startX + lightRadius * 2 + lightSpacing, y: centerY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.03, alpha: 1.0), intensity: y)
        drawLight(ctx: ctx, center: CGPoint(x: startX + (lightRadius * 2 + lightSpacing) * 2, y: centerY), radius: lightRadius,
                  onColor: NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.30, alpha: 1.0), intensity: g)
    }

    private func drawLight(ctx: CGContext, center: CGPoint, radius: CGFloat, onColor: NSColor, intensity: CGFloat) {
        let r = radius

        // Glow
        if intensity > 0.3 {
            let glowR = r + 3 * intensity
            let glowColor = onColor.withAlphaComponent(intensity * 0.3)
            ctx.setFillColor(glowColor.cgColor)
            ctx.fillEllipse(in: NSRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2))
        }

        // Bezel
        let bezelColor = NSColor(white: 0.06, alpha: 1.0)
        ctx.setFillColor(bezelColor.cgColor)
        ctx.fillEllipse(in: NSRect(x: center.x - r - 1, y: center.y - r - 1, width: (r + 1) * 2, height: (r + 1) * 2))

        // Bulb
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

func signalToState(_ signal: String) -> StatusBarLightView.LightState {
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var lightView: StatusBarLightView!
    let backend = BackendManager()
    let monitor = CFProcessMonitor()
    var cfRunning = false
    var currentSummary = "等待 cf 启动…"
    let sseClient = SSEClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        backend.start()

        // Create status bar item with custom view
        let lightW: CGFloat = 42
        let lightH: CGFloat = 22
        statusItem = NSStatusBar.system.statusItem(withLength: lightW)
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            lightView = StatusBarLightView(frame: NSRect(x: 0, y: 0, width: lightW, height: lightH))
            button.addSubview(lightView)
            lightView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lightView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                lightView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                lightView.widthAnchor.constraint(equalToConstant: lightW),
                lightView.heightAnchor.constraint(equalToConstant: lightH),
            ])
            button.toolTip = currentSummary
        }

        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: currentSummary, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // SSE
        connectSSE()

        // CF process monitoring
        monitor.onCFStart = { [weak self] in
            guard let self else { return }
            self.cfRunning = true
            self.lightView.state = .idle
            self.updateStatus("空闲")
        }

        monitor.onCFExit = { [weak self] in
            guard let self else { return }
            self.cfRunning = false
            self.lightView.state = .waiting
            self.updateStatus("等待 cf 启动…")
        }

        monitor.start()

        // Check initial state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.cfRunning == true {
                self?.lightView.state = .idle
                self?.updateStatus("空闲")
            }
        }
    }

    private func updateStatus(_ text: String) {
        currentSummary = text
        if let button = statusItem.button {
            button.toolTip = text
        }
        if let menu = statusItem.menu, menu.items.count > 0 {
            menu.items[0].title = text
        }
    }

    @MainActor private func connectSSE() {
        sseClient.connect(url: "http://127.0.0.1:9876/events") { [weak self] jsonStr in
            guard let self else { return }
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let signal = json["signal"] as? String ?? "idle"
                let summary = json["summary"] as? String ?? ""
                let attention = json["attention"] as? String ?? ""
                let state = signalToState(signal)
                let statusText = attention.isEmpty ? summary : "\(summary) · \(attention)"
                DispatchQueue.main.async {
                    self.lightView?.state = state
                    self.updateStatus(statusText)
                }
            }
        }
    }

    @MainActor @objc func quit() {
        monitor.stop()
        backend.stop()
        NSApp.terminate(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Return focus to whichever app was frontmost before us
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return // another app is already frontmost, nothing to do
        }
        // We became frontmost — activate the previous app instead
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        if let prev = apps.last(where: { $0.isActive }) ?? apps.last {
            prev.activate()
        } else {
            NSApp.deactivate()
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
