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

// MARK: - CLI Process Monitor (cf + claude)

class CLIProcessMonitor {
    private var timer: Timer?
    private var wasCFRunning = false
    private var wasClaudeRunning = false
    private var lastClaudeState: StatusBarLightView.LightState = .idle
    var onCLIStart: (() -> Void)?
    var onCLIExit: (() -> Void)?
    var onClaudeStateChange: ((StatusBarLightView.LightState) -> Void)?
    private let claudeProjectsPath: String

    init() {
        let home = NSHomeDirectory() as NSString
        claudeProjectsPath = home.appendingPathComponent(".claude/projects")
    }

    func start() {
        wasCFRunning = isProcessRunning("cf")
        wasClaudeRunning = isProcessRunning("claude")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkProcesses()
        }
        timer?.tolerance = 0.3
    }

    func isRunning() -> Bool {
        return wasCFRunning || wasClaudeRunning
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func isProcessRunning(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // Scan ~/.claude/projects/ for latest .jsonl mtime
    private func latestTranscriptAge() -> TimeInterval {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeProjectsPath) else {
            return 99999
        }
        var latestMtime: Date = .distantPast
        for dir in projectDirs {
            let dirPath = (claudeProjectsPath as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files {
                if file.hasSuffix(".jsonl") {
                    let filePath = (dirPath as NSString).appendingPathComponent(file)
                    if let attrs = try? fm.attributesOfItem(atPath: filePath),
                       let mtime = attrs[.modificationDate] as? Date,
                       mtime > latestMtime {
                        latestMtime = mtime
                    }
                }
            }
        }
        return Date().timeIntervalSince(latestMtime)
    }

    private func checkProcesses() {
        let cfRunning = isProcessRunning("cf")
        let claudeRunning = isProcessRunning("claude")
        let anyRunning = cfRunning || claudeRunning
        let wasAnyRunning = wasCFRunning || wasClaudeRunning

        if anyRunning && !wasAnyRunning {
            onCLIStart?()
        } else if !anyRunning && wasAnyRunning {
            onCLIExit?()
        }

        wasCFRunning = cfRunning
        wasClaudeRunning = claudeRunning

        // Claude 3-phase via transcript .jsonl freshness:
        // fresh (<3s) → thinking (yellow), stale (<10s) → blocked (red), very stale → idle (green)
        if claudeRunning {
            let transcriptAge = latestTranscriptAge()
            let newState: StatusBarLightView.LightState
            if transcriptAge < 3 {
                newState = .thinking
            } else if transcriptAge < 10 {
                newState = .blocked
            } else {
                newState = .idle
            }
            if newState != lastClaudeState {
                lastClaudeState = newState
                onClaudeStateChange?(newState)
            }
        } else if lastClaudeState != .idle {
            lastClaudeState = .idle
            onClaudeStateChange?(.idle)
        }
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

func statePriority(_ state: StatusBarLightView.LightState) -> Int {
    switch state {
    case .blocked: return 5
    case .permission: return 4
    case .attention: return 3
    case .thinking, .working, .tool_done: return 2
    case .done: return 1
    case .idle, .session_start, .session_end, .waiting: return 0
    }
}

func higherPriorityState(_ a: StatusBarLightView.LightState, _ b: StatusBarLightView.LightState) -> StatusBarLightView.LightState {
    return statePriority(a) >= statePriority(b) ? a : b
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

// MARK: - Single Instance

func ensureSingleInstance() {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier ?? "com.codeflicker.signallight"
    let hasOtherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != currentPID }
    if hasOtherInstance {
        exit(0)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var lightView: StatusBarLightView!
    let backend = BackendManager()
    let monitor = CLIProcessMonitor()
    var cliRunning = false
    var currentSummary = "等待启动…"
    let sseClient = SSEClient()
    var cfLightState: StatusBarLightView.LightState = .idle
    var claudeLightState: StatusBarLightView.LightState? = nil
    var cfSummary: String = ""
    var claudeSummary: String = ""
    let idleIcon: NSImage = {
        let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Signal Light")!
        img.size = NSSize(width: 14, height: 14)
        return img
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        backend.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = idleIcon
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

        // CLI process monitoring (cf + claude)
        monitor.onCLIStart = { [weak self] in
            guard let self else { return }
            self.cliRunning = true
            // If claude is running, initialize its state
            if self.claudeLightState == nil {
                self.claudeLightState = .idle
                self.claudeSummary = "Claude 空闲"
            }
            self.showTrafficLight()
        }

        monitor.onCLIExit = { [weak self] in
            guard let self else { return }
            self.cliRunning = false
            self.claudeLightState = nil
            self.cfLightState = .idle
            self.cfSummary = ""
            self.claudeSummary = ""
            self.showIdleIcon()
        }

        monitor.onClaudeStateChange = { [weak self] state in
            guard let self else { return }
            self.claudeLightState = state
            switch state {
            case .thinking: self.claudeSummary = "Claude 思考中"
            case .blocked: self.claudeSummary = "Claude 等待处理"
            default: self.claudeSummary = "Claude 空闲"
            }
            self.mergeAndApplyLight()
        }

        monitor.start()

        if monitor.isRunning() {
            cliRunning = true
            // If claude is running, init its state so mergeAndApplyLight can use it
            if claudeLightState == nil {
                claudeLightState = .idle
                claudeSummary = "Claude 空闲"
            }
            showTrafficLight()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.cliRunning == true {
                self?.showTrafficLight()
            }
        }
    }

    private func showTrafficLight() {
        let lightW: CGFloat = 42
        let lightH: CGFloat = 22
        statusItem.length = lightW
        if let button = statusItem.button {
            button.image = nil
            if lightView == nil {
                lightView = StatusBarLightView(frame: NSRect(x: 0, y: 0, width: lightW, height: lightH))
                button.addSubview(lightView)
                lightView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    lightView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    lightView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    lightView.widthAnchor.constraint(equalToConstant: lightW),
                    lightView.heightAnchor.constraint(equalToConstant: lightH),
                ])
            }
            lightView.state = .idle
            lightView.isHidden = false
        }
        updateStatus("空闲")
    }

    private func showIdleIcon() {
        statusItem.length = NSStatusItem.squareLength
        if let button = statusItem.button {
            lightView?.isHidden = true
            button.image = idleIcon
        }
        updateStatus("等待启动…")
    }

    private func mergeAndApplyLight() {
        guard cliRunning else { return }

        let merged: StatusBarLightView.LightState
        let mergedSummary: String

        if let claudeState = claudeLightState {
            // Both CLIs: show higher priority state
            if statePriority(claudeState) > statePriority(cfLightState) {
                merged = claudeState
                mergedSummary = claudeSummary
            } else if statePriority(cfLightState) > statePriority(claudeState) {
                merged = cfLightState
                mergedSummary = cfSummary.isEmpty ? "空闲" : cfSummary
            } else {
                // Same priority: combine
                merged = cfLightState
                var parts: [String] = []
                if !cfSummary.isEmpty { parts.append("cf: \(cfSummary)") }
                if !claudeSummary.isEmpty { parts.append(claudeSummary) }
                mergedSummary = parts.isEmpty ? "空闲" : parts.joined(separator: " | ")
            }
        } else {
            merged = cfLightState
            mergedSummary = cfSummary.isEmpty ? "空闲" : cfSummary
        }

        lightView?.state = merged
        updateStatus(mergedSummary)
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
                    self.cfLightState = state
                    self.cfSummary = statusText
                    self.mergeAndApplyLight()
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

ensureSingleInstance()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
