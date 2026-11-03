import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func axText(_ element: AXUIElement, _ name: String) -> String {
    if let value = attribute(element, name) as? String { return value }
    return ""
}
func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

struct Snapshot {
    let pid: pid_t
    let nodes: [UINode]
    let elements: [Int: AXUIElement]
    let fullValues: [Int: String]
    let window: AXUIElement
    let partial: Bool
}

final class DesktopAccess {
    func snapshot(pid: pid_t) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw AgentError.message("Enable Swarm Desktop in System Settings → Privacy & Security → Accessibility, then observe again.") }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw AgentError.message("The selected app has closed.")
        }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var windowList: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowList)
        var focusedWindow: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        let windows = windowList as? [AXUIElement] ?? []
        guard let window = axElement(focusedWindow) ?? windows.first else {
            throw AgentError.message("No accessible window in \(app.localizedName ?? "selected app"). AXWindows: \(windowError.rawValue), AXFocusedWindow: \(focusedError.rawValue). Open its window; if permission was just granted, restart Swarm Desktop.")
        }
        AXUIElementSetMessagingTimeout(root, 0.2)
        var nodes: [UINode] = []
        var elements: [Int: AXUIElement] = [:]
        var fullValues: [Int: String] = [:]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var count = 0
        var partial = false
        let deadline = Date().addingTimeInterval(3)
        func walk(_ element: AXUIElement, depth: Int) {
            guard count < 1000, nodes.count < 70, depth < 20, Date() < deadline else { partial = true; return }
            let hash = CFHash(element)
            guard !(visited[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            visited[hash, default: []].append(element)
            count += 1
            let role = axText(element, kAXRoleAttribute)
            let subrole = axText(element, kAXSubroleAttribute)
            // Never include a secure field's label, value, or descendants in model input.
            guard subrole != kAXSecureTextFieldSubrole else { return }
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            let available = names as? [String] ?? []
            var actions: [String] = []
            let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
            if enabled && available.contains(kAXPressAction) { actions.append("press") }
            var writable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
            if enabled && writable.boolValue && [kAXTextFieldRole, kAXTextAreaRole].contains(role) {
                actions.append("set_text")
            }
            var label = axText(element, kAXTitleAttribute)
            if label.isEmpty { label = axText(element, kAXDescriptionAttribute) }
            if label.isEmpty { label = axText(element, kAXHelpAttribute) }
            if label.isEmpty, let title = axElement(attribute(element, kAXTitleUIElementAttribute)) {
                label = axText(title, kAXValueAttribute)
            }
            let value = axText(element, kAXValueAttribute)
            if !actions.isEmpty || role == kAXStaticTextRole || role == kAXWindowRole {
                let id = nodes.count + 1
                nodes.append(UINode(id: id, role: role, label: String(label.prefix(120)),
                                    value: String(value.prefix(300)), actions: actions))
                elements[id] = element
                if !actions.isEmpty { fullValues[id] = value }
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
                if partial && (nodes.count >= 70 || Date() >= deadline) { break }
            }
        }
        walk(window, depth: 0)
        return Snapshot(pid: pid, nodes: nodes, elements: elements, fullValues: fullValues, window: window, partial: partial)
    }

    // Re-observe and compare the approved state before touching any target.
    func validateFresh(_ snapshot: Snapshot, action: AgentAction) throws -> AXUIElement {
        try action.validate(nodes: snapshot.nodes)
        let current = try self.snapshot(pid: snapshot.pid)
        guard CFEqual(current.window, snapshot.window), current.nodes == snapshot.nodes,
              current.fullValues == snapshot.fullValues,
              let old = snapshot.elements[action.target], let fresh = current.elements[action.target],
              CFEqual(old, fresh) else {
            throw AgentError.message("The window changed after planning. Observe and plan again.")
        }
        return fresh
    }

    func execute(_ action: AgentAction, element: AXUIElement, pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw AgentError.message("Target app is no longer running.")
        }
        app.activate(options: [])
        let result: AXError
        if action.action == "press" {
            result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        } else if action.action == "set_text" {
            result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, action.text as CFString)
        } else { throw AgentError.message("This response has no executable action.") }
        guard result == .success else { throw AgentError.message("App rejected the action (Accessibility error \(result.rawValue)).") }
    }
}

// Visual workers are local animation. Only one approved AX action is ever issued.
final class CursorView: NSView {
    var position = CGPoint(x: 20, y: 20)
    var destination = CGPoint(x: 20, y: 20)
    let palette: [NSColor] = [.systemPurple, .systemTeal, .systemOrange]
    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<1 {
            let p = CGPoint(x: position.x - CGFloat(index * 38), y: position.y + CGFloat(index * 25))
            let path = NSBezierPath()
            path.move(to: p)
            path.line(to: CGPoint(x: p.x + 4, y: p.y - 23))
            path.line(to: CGPoint(x: p.x + 10, y: p.y - 16))
            path.line(to: CGPoint(x: p.x + 22, y: p.y - 15))
            path.close()
            palette[index].setFill(); path.fill()
            NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
            let label = ["Act", "Plan", "Observe"][index]
            (label as NSString).draw(at: CGPoint(x: p.x + 24, y: p.y - 22), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: palette[index],
                .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.92)])
        }
    }
}

final class CursorOverlay {
    var panel: NSPanel?
    var view: CursorView?
    var timer: Timer?
    func show(at axFrame: CGRect?) {
        hide()
        guard let axFrame = axFrame, axFrame.width > 0, axFrame.height > 0,
              let primary = NSScreen.screens.first else { return }
        let point = CGPoint(x: axFrame.midX, y: primary.frame.maxY - axFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = CursorView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.destination = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        view.position = CGPoint(x: view.destination.x - 180, y: view.destination.y + 90)
        panel.contentView = view
        self.panel = panel; self.view = view
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let view = self?.view else { return }
            view.position.x += (view.destination.x - view.position.x) * 0.16
            view.position.y += (view.destination.y - view.position.y) * 0.16
            view.needsDisplay = true
        }
    }
    func hide() { timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil; view = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var targetMenu = NSPopUpButton()
    var applications: [NSRunningApplication] = []
    let goal = NSTextField(string: "")
    let model = NSTextField(string: "qwen3:0.6b")
    let reasoning = NSButton(checkboxWithTitle: "Reason before acting (slower, more reliable in testing)", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "Choose an app and describe one concrete task.")
    let proposal = NSTextField(wrappingLabelWithString: "No action proposed.")
    let observation = NSTextView()
    let planButton = NSButton(title: "Plan next action", target: nil, action: nil)
    let runButton = NSButton(title: "Approve & run this action", target: nil, action: nil)
    let observeButton = NSButton(title: "Observe", target: nil, action: nil)
    let planner = Planner()
    let access = DesktopAccess()
    let overlay = CursorOverlay()
    let fleet = FleetOverlay()
    let fleetStatus = NSTextField(wrappingLabelWithString: "Codex bridge: starting…")
    var bridge: DesktopBridge?
    var bridgeSnapshots: [String: (Snapshot, Date)] = [:]
    var staged: [String: (AgentAction, String, String)] = [:]
    var snapshot: Snapshot?
    var pending: AgentAction?
    var generation = 0
    var planning = false
    var practice: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Swarm Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Swarm Desktop · Local Agent"
        window.minSize = NSSize(width: 680, height: 700)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)])
        let heading = NSTextField(labelWithString: "SWARM / DESKTOP")
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        stack.addArrangedSubview(heading)
        let subtitle = NSTextField(wrappingLabelWithString: "Codex coordinates. Loupe works locally. Desktop actions take turns.")
        subtitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(subtitle)
        let bridgeRow = NSStackView(views: [fleetStatus, button("Resume Codex", #selector(resumeBridge))])
        bridgeRow.spacing = 8; fleetStatus.font = .systemFont(ofSize: 11); fleetStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(bridgeRow)
        let refresh = button("Refresh apps", #selector(refreshApps))
        let permission = button("Enable Accessibility…", #selector(enableAccess))
        let practiceButton = button("Open practice app", #selector(openPractice))
        let top = NSStackView(views: [targetMenu, refresh, permission]); top.spacing = 8
        targetMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        targetMenu.target = self; targetMenu.action = #selector(targetChanged)
        stack.addArrangedSubview(top)
        let modelRow = NSStackView(views: [NSTextField(labelWithString: "Ollama model"), model, practiceButton])
        model.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        modelRow.spacing = 10; stack.addArrangedSubview(modelRow)
        reasoning.state = .on; reasoning.target = self; reasoning.action = #selector(reasoningChanged)
        stack.addArrangedSubview(reasoning)
        goal.placeholderString = "Example: Set the Name field to Ada Lovelace"
        goal.font = .systemFont(ofSize: 15); goal.delegate = self; model.delegate = self
        stack.addArrangedSubview(goal); goal.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        observeButton.target = self; observeButton.action = #selector(observe)
        planButton.target = self; planButton.action = #selector(plan)
        runButton.target = self; runButton.action = #selector(runAction); runButton.isEnabled = false
        let stop = button("Stop", #selector(stop))
        let actions = NSStackView(views: [observeButton, planButton, runButton, stop]); actions.spacing = 8
        stack.addArrangedSubview(actions)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        proposal.font = .systemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(proposal); proposal.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let label = NSTextField(labelWithString: "OBSERVED WINDOW · sent only to local Ollama when you plan")
        label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        observation.isEditable = false; observation.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        observation.textContainerInset = NSSize(width: 10, height: 10)
        observation.autoresizingMask = [.width]; observation.isVerticallyResizable = true
        observation.textContainer?.widthTracksTextView = true
        scroll.documentView = observation
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let foot = NSTextField(wrappingLabelWithString: "Use this panel for individual steps, or let Codex coordinate jobs through the bridge. Codex may execute staged actions within your chat authorization. Stop pauses the bridge and cancels local jobs.")
        foot.font = .systemFont(ofSize: 11); foot.textColor = .secondaryLabelColor
        stack.addArrangedSubview(foot)
        refreshApps()
        setupBridge()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    func invalidate() {
        generation += 1; planner.cancel(); pending = nil; runButton.isEnabled = false
        planning = false; planButton.isEnabled = true; overlay.hide()
    }
    func controlTextDidChange(_ obj: Notification) {
        invalidate(); proposal.stringValue = "Task or model changed. Plan again."
    }
    @objc func reasoningChanged() { invalidate(); proposal.stringValue = "Planning mode changed. Plan again." }
    @objc func targetChanged() {
        invalidate(); snapshot = nil; observation.string = ""; proposal.stringValue = "Observe the selected app to begin."
    }
    @objc func refreshApps() {
        let previous = applications.indices.contains(targetMenu.indexOfSelectedItem) ? applications[targetMenu.indexOfSelectedItem].processIdentifier : nil
        applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        targetMenu.removeAllItems()
        targetMenu.addItems(withTitles: applications.map { $0.localizedName ?? "App \($0.processIdentifier)" })
        if let index = applications.firstIndex(where: { $0.processIdentifier == previous }) { targetMenu.selectItem(at: index) }
        targetChanged()
    }
    @objc func enableAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { status.stringValue = "Accessibility is enabled. Choose an app, then Observe." }
        else { status.stringValue = "Enable Swarm Desktop in Accessibility settings. Then return and click Observe." }
    }
    func selectedPID() throws -> pid_t {
        guard applications.indices.contains(targetMenu.indexOfSelectedItem) else { throw AgentError.message("Choose a running desktop app.") }
        return applications[targetMenu.indexOfSelectedItem].processIdentifier
    }
    func render(_ snapshot: Snapshot) {
        observation.string = snapshot.nodes.map {
            "[\($0.id)] \($0.role) · \($0.label)\n    value: \($0.value)  actions: \($0.actions.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
    @objc func observe() {
        invalidate()
        do {
            let current = try access.snapshot(pid: selectedPID()); snapshot = current; render(current)
            status.stringValue = "Observed \(current.nodes.count) elements.\(current.partial ? " Partial view; additional controls may be omitted." : "")"
            proposal.stringValue = "Ready to plan. No action has run."
        } catch { snapshot = nil; status.stringValue = error.localizedDescription }
    }
    @objc func plan() {
        guard !planning else { return }
        let taskGoal = goal.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskGoal.isEmpty && !modelName.isEmpty else { status.stringValue = "Enter a goal and a locally installed Ollama model."; return }
        guard !modelName.contains(":cloud") && !modelName.contains("-cloud") && !modelName.contains("/") else {
            status.stringValue = "Choose a local Ollama model tag."; return
        }
        observe()
        guard let current = snapshot else { return }
        guard !current.nodes.isEmpty else { status.stringValue = "No accessible controls found in this window."; return }
        let version = generation
        planning = true; planButton.isEnabled = false
        status.stringValue = "Qwen is planning locally… Animation never waits on model tokens."
        planner.plan(model: modelName, goal: taskGoal, nodes: current.nodes, thinking: reasoning.state == .on,
                     resourceDirectory: Bundle.main.resourceURL!) { [weak self] result in
            guard let self = self, self.generation == version else { return }
            self.planning = false; self.planButton.isEnabled = true
            switch result {
            case .failure(let error): self.status.stringValue = error.localizedDescription
            case .success(let result):
                let action = result.action
                self.status.stringValue = String(format: "Local decision: %.2f s · %.1f tokens/s · review the exact action below.", result.seconds, result.tokensPerSecond)
                if action.action == "done" || action.action == "blocked" {
                    self.proposal.stringValue = "Model says \(action.action): \(action.reason)"; return
                }
                self.pending = action; self.runButton.isEnabled = true
                let node = current.nodes.first(where: { $0.id == action.target })!
                self.proposal.stringValue = "Proposed: \(action.action) → [\(action.target)] \(node.label)\(action.action == "set_text" ? "\nReplace value with: \(action.text)" : "")\n\(action.reason)"
                if let element = current.elements[action.target] { self.overlay.show(at: elementFrame(element)) }
            }
        }
    }
    @objc func runAction() {
        guard bridge?.busy != true else { status.stringValue = "Another desktop action is in progress."; return }
        guard let action = pending, let approved = snapshot else { return }
        pending = nil; runButton.isEnabled = false
        do {
            let element = try access.validateFresh(approved, action: action)
            try access.execute(action, element: element, pid: approved.pid)
            bridge?.busy = true
            let version = generation
            status.stringValue = "App accepted the action. Observing the result…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.bridge?.busy = false
                guard self.generation == version else { return }
                self.overlay.hide()
                do {
                    let current = try self.access.snapshot(pid: approved.pid)
                    self.snapshot = current; self.render(current)
                    let changed = current.nodes != approved.nodes
                    self.status.stringValue = changed ? "Action accepted; visible state changed. Review it before planning the next step." : "Action accepted, but no visible change detected. Inspect the app before retrying."
                    self.proposal.stringValue = "Last action: \(action.action) on [\(action.target)]. No further action queued."
                } catch { self.snapshot = nil; self.status.stringValue = "Action accepted; verification unavailable: \(error.localizedDescription)" }
            }
        } catch { overlay.hide(); snapshot = nil; status.stringValue = error.localizedDescription }
    }
    @objc func stop() {
        invalidate(); snapshot = nil; bridge?.paused = true; staged.removeAll(); bridgeSnapshots.removeAll()
        fleet.hide(); status.stringValue = "Stopped. Codex bridge paused; local jobs will be cancelled."; proposal.stringValue = ""
    }
    @objc func resumeBridge() { bridge?.paused = false; status.stringValue = "Codex bridge resumed. Cancelled jobs are not replayed." }

    func setupBridge() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "SwarmBridgeDirectory") as? String else { return }
        let bridge = DesktopBridge(directory: URL(fileURLWithPath: path)); self.bridge = bridge
        bridge.status = { [weak self] in
            ["accessibility": AXIsProcessTrusted(), "version": "0.2.0",
             "apps": NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
             }.map { ["pid": $0.processIdentifier, "name": $0.localizedName ?? "App", "bundle_id": $0.bundleIdentifier ?? ""] as [String: Any] },
             "staged_count": self?.staged.count ?? 0]
        }
        bridge.onJobs = { [weak self] jobs in
            guard let self = self else { return }
            let paused = self.bridge?.paused ?? true
            self.fleetStatus.stringValue = paused ? "Codex bridge paused" : "Codex bridge ready · \(jobs.count) task cursors"
            if !paused { self.fleet.update(jobs) }
        }
        bridge.handler = { [weak self] request, reply in self?.handleBridge(request, reply: reply) }
        bridge.start()
    }

    func storeSnapshot(_ observed: Snapshot) throws -> [String: Any] {
        bridgeSnapshots = bridgeSnapshots.filter { Date().timeIntervalSince($0.value.1) < 120 }
        if bridgeSnapshots.count >= 20, let oldest = bridgeSnapshots.min(by: { $0.value.1 < $1.value.1 })?.key {
            bridgeSnapshots.removeValue(forKey: oldest)
        }
        let id = UUID().uuidString
        bridgeSnapshots[id] = (observed, Date())
        return ["snapshot_id": id, "pid": observed.pid, "partial": observed.partial,
                "nodes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed.nodes)),
                "expires_in_seconds": 120]
    }
    func handleBridge(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        do {
            switch request["command"] as? String {
            case "observe":
                guard let pid = request["pid"] as? Int, pid != Int(ProcessInfo.processInfo.processIdentifier), pid > 0, pid <= Int(Int32.max) else {
                    throw AgentError.message("Choose a valid target app PID from swarm_status.")
                }
                let current = try access.snapshot(pid: pid_t(pid))
                reply(try storeSnapshot(current))
            case "stage":
                guard let id = request["snapshot_id"] as? String, let stored = bridgeSnapshots[id],
                      Date().timeIntervalSince(stored.1) < 120, let actionJSON = request["action"] as? [String: Any],
                      let jobID = request["job_id"] as? String, UUID(uuidString: jobID) != nil else {
                    throw AgentError.message("Missing or expired observation. Observe the target app again.")
                }
                staged = staged.filter { _, value in
                    guard let snapshot = bridgeSnapshots[value.1] else { return false }
                    return Date().timeIntervalSince(snapshot.1) < 120
                }
                guard staged.count < 20 else { throw AgentError.message("Too many staged actions. Execute or cancel existing jobs first.") }
                let action = try JSONDecoder().decode(AgentAction.self, from: JSONSerialization.data(withJSONObject: actionJSON))
                guard ["press", "set_text"].contains(action.action) else { throw AgentError.message("Only button presses and text edits can be staged.") }
                try action.validate(nodes: stored.0.nodes)
                let title = String((request["title"] as? String ?? "Desktop task").prefix(80))
                staged[jobID] = (action, id, title)
                reply(["job_id": jobID, "state": "staged", "action": actionJSON,
                       "target": stored.0.nodes.first(where: { $0.id == action.target })?.label ?? ""])
            case "cancel":
                if let id = request["job_id"] as? String { staged.removeValue(forKey: id) }
                reply(["state": "cancelled"])
            case "execute":
                guard let jobID = request["job_id"] as? String, let entry = staged.removeValue(forKey: jobID),
                      let stored = bridgeSnapshots[entry.1], Date().timeIntervalSince(stored.1) < 120 else {
                    throw AgentError.message("No fresh staged action. Observe and stage again; never blindly retry execution.")
                }
                let (action, _, title) = entry
                let observed = stored.0
                let target = try access.validateFresh(observed, action: action)
                invalidate()
                overlay.show(at: elementFrame(target))
                status.stringValue = "Codex executing: \(title)"
                proposal.stringValue = "\(action.action) on element \(action.target)\(action.action == "set_text" ? ": \(action.text)" : "")"
                try access.execute(action, element: target, pid: observed.pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { reply(["error": "Agent closed during verification; outcome unknown."]); return }
                    self.overlay.hide()
                    do {
                        let current = try self.access.snapshot(pid: observed.pid)
                        var result = try self.storeSnapshot(current)
                        result["job_id"] = jobID; result["state"] = "executed"
                        result["visible_change"] = current.nodes != observed.nodes
                        result["goal_verified"] = false
                        self.status.stringValue = "Codex action accepted; resulting state returned for verification."
                        reply(result)
                    } catch { reply(["job_id": jobID, "state": "executed", "verification_error": error.localizedDescription, "goal_verified": false]) }
                }
            default: throw AgentError.message("Unknown desktop bridge command.")
            }
        } catch { overlay.hide(); reply(["error": error.localizedDescription]) }
    }
    @objc func openPractice() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Swarm Practice.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error { self?.status.stringValue = error.localizedDescription }
                else { self?.refreshApps() }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { planner.cancel(); overlay.hide(); fleet.hide(); bridge?.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
