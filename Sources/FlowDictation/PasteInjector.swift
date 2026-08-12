import AppKit
import ApplicationServices

final class PasteInjector {
    func insert(_ text: String, into targetApplication: NSRunningApplication?, restoreAfter milliseconds: Int) {
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map(copyPasteboardItem)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        targetApplication?.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        pasteWhenTargetIsReady(targetApplication, attempt: 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(100, milliseconds))) {
                guard pasteboard.changeCount == replacementChangeCount else { return }
                pasteboard.clearContents()
                if !previousItems.isEmpty {
                    pasteboard.writeObjects(previousItems)
                }
            }
        }
    }

    private func pasteWhenTargetIsReady(
        _ targetApplication: NSRunningApplication?,
        attempt: Int,
        completion: @escaping () -> Void
    ) {
        let targetIsActive: Bool
        if let targetApplication {
            targetIsActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplication.processIdentifier
        } else {
            targetIsActive = true
        }

        if targetIsActive || attempt >= 5 {
            sendPasteKeystroke()
            completion()
            return
        }

        targetApplication?.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            self?.pasteWhenTargetIsReady(targetApplication, attempt: attempt + 1, completion: completion)
        }
    }

    private func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func copyPasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
}
