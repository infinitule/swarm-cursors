import AppKit

final class Practice: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let name = NSTextField(string: "")
    let title = NSTextField(string: "")
    let result = NSTextField(labelWithString: "Not saved")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 460, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Swarm Practice"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.frame = NSRect(x: 24, y: 24, width: 412, height: 250)
        let heading = NSTextField(labelWithString: "A desktop playground")
        heading.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(heading)
        name.placeholderString = "Name"; name.setAccessibilityLabel("Name")
        title.placeholderString = "Title"; title.setAccessibilityLabel("Title")
        for field in [name, title] { stack.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 410).isActive = true }
        stack.addArrangedSubview(NSButton(title: "Save", target: self, action: #selector(save)))
        stack.addArrangedSubview(result)
        let note = NSTextField(labelWithString: "Practice data stays in memory and resets when closed.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        window.contentView!.addSubview(stack)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func save() { result.stringValue = "Saved: \(name.stringValue) · \(title.stringValue)" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Practice(); app.delegate = delegate
app.setActivationPolicy(.regular); app.run()
