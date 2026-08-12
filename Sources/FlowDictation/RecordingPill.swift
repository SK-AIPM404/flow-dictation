import AppKit

final class RecordingPill {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 156, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: panel.contentView!.bounds)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.98).cgColor
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 19
        content.layer?.masksToBounds = true

        let dot = NSView(frame: NSRect(x: 15, y: 15, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        content.addSubview(dot)

        label = NSTextField(labelWithString: "Recording")
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 35, y: 9, width: 104, height: 20)
        content.addSubview(label)
        panel.contentView = content
    }

    func show() {
        label.stringValue = "Recording"
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 76))
        panel.orderFrontRegardless()
    }

    func showTranscribing() {
        label.stringValue = "Transcribing"
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
