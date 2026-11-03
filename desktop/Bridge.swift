import AppKit

// Private local IPC. Codex speaks MCP to Python; this app owns all Accessibility actions.
final class DesktopBridge {
    let directory: URL
    var handler: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    var status: (() -> [String: Any])?
    var onJobs: (([[String: Any]]) -> Void)?
    var timer: Timer?
    var busy = false
    var paused = false
    init(directory: URL) {
        self.directory = directory
        for name in ["", "requests", "processing", "responses", "sessions"] {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(name),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        var state = status?() ?? [:]
        state["heartbeat"] = Date().timeIntervalSince1970
        state["paused"] = paused
        state["busy"] = busy
        write(state, to: directory.appendingPathComponent("status.json"))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? []
        var jobs: [[String: Any]] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let heartbeat = session["heartbeat"] as? Double,
                  Date().timeIntervalSince1970 - heartbeat < 10 else { continue }
            jobs += session["jobs"] as? [[String: Any]] ?? []
        }
        onJobs?(Array(jobs.prefix(8)))
        guard !busy else { return }
        let inbox = directory.appendingPathComponent("requests")
        let requests = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let file = requests.first else { return }
        let claimed = directory.appendingPathComponent("processing").appendingPathComponent(file.lastPathComponent)
        do { try FileManager.default.moveItem(at: file, to: claimed) } catch { return }
        let response = directory.appendingPathComponent("responses").appendingPathComponent(file.lastPathComponent)
        let finish: ([String: Any]) -> Void = { [weak self] result in
            self?.write(result, to: response)
            try? FileManager.default.removeItem(at: claimed)
            self?.busy = false
        }
        busy = true
        guard let data = try? Data(contentsOf: claimed), data.count < 64000,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deadline = request["deadline"] as? Double, deadline > Date().timeIntervalSince1970 else {
            finish(["error": "Expired or invalid request. Nothing executed."]); return
        }
        guard !paused else { finish(["error": "Desktop bridge is stopped. Resume it in Swarm Desktop."]); return }
        handler?(request, finish)
    }
    func stop() { timer?.invalidate(); timer = nil }
}

// One marker per real MCP job. The side rail is a task indicator, not a claimed click location.
final class FleetView: NSView {
    var jobs: [[String: Any]] = []
    override func draw(_ dirtyRect: NSRect) {
        for (index, job) in jobs.enumerated() {
            let y = bounds.height - 90 - CGFloat(index * 52)
            let x = bounds.width - 310
            let color: NSColor = [.systemPurple, .systemTeal, .systemOrange, .systemBlue][index % 4]
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x, y: y)); arrow.line(to: NSPoint(x: x + 4, y: y - 23))
            arrow.line(to: NSPoint(x: x + 10, y: y - 16)); arrow.line(to: NSPoint(x: x + 22, y: y - 15)); arrow.close()
            color.setFill(); arrow.fill(); NSColor.white.setStroke(); arrow.lineWidth = 1.2; arrow.stroke()
            let label = "\(job["title"] as? String ?? "Task") · \(job["state"] as? String ?? "queued")"
            (String(label.prefix(50)) as NSString).draw(at: NSPoint(x: x + 28, y: y - 20), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color,
                .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.94)])
        }
    }
}

final class FleetOverlay {
    var panel: NSPanel?
    var view: FleetView?
    func update(_ jobs: [[String: Any]]) {
        guard !jobs.isEmpty, let screen = NSScreen.screens.first else { hide(); return }
        if panel == nil {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true; p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = FleetView(frame: CGRect(origin: .zero, size: screen.frame.size))
            p.contentView = v; panel = p; view = v; p.orderFrontRegardless()
        }
        view?.jobs = jobs; view?.needsDisplay = true
    }
    func hide() { panel?.orderOut(nil); panel = nil; view = nil }
}
