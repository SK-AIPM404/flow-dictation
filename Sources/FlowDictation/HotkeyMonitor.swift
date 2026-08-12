import ApplicationServices
import AppKit
import Foundation

final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let settings: HotkeySettings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isPressed = false
    private var fnReleasePoller: Timer?
    private var fnPressedAt: Date?

    init(settings: HotkeySettings) {
        self.settings = settings
    }

    deinit { stop() }

    func start() -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.callback,
            userInfo: pointer
        )
        guard let eventTap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        installAppKitMonitors()
        return true
    }

    func stop() {
        fnReleasePoller?.invalidate()
        fnReleasePoller = nil
        fnPressedAt = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        isPressed = false
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        switch settings.kind {
        case .fn:
            guard type == .flagsChanged else { return }
            let pressed = event.flags.contains(.maskSecondaryFn)
            setPressed(pressed)
        case .shortcut:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == settings.keyCode else { return }
            if type == .keyDown {
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeated && matchesConfiguredModifiers(event.flags) { setPressed(true) }
            } else if type == .keyUp, isPressed {
                setPressed(false)
            }
        }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        updateFnReleasePoller(for: pressed)
        DispatchQueue.main.async { [weak self] in
            pressed ? self?.onPress?() : self?.onRelease?()
        }
    }

    private func installAppKitMonitors() {
        guard settings.kind == .fn else { return }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleAppKitFlags(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleAppKitFlags(event)
            return event
        }
    }

    private func handleAppKitFlags(_ event: NSEvent) {
        guard settings.kind == .fn else { return }
        setPressed(event.modifierFlags.contains(.function))
    }

    private func updateFnReleasePoller(for pressed: Bool) {
        guard settings.kind == .fn else { return }
        fnReleasePoller?.invalidate()
        fnReleasePoller = nil
        fnPressedAt = pressed ? Date() : nil
        guard pressed else { return }

        fnReleasePoller = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let flags = CGEventSource.flagsState(.hidSystemState)
            let fnIsStillHeld = flags.contains(.maskSecondaryFn)
            let heldTooLong = self.fnPressedAt.map { Date().timeIntervalSince($0) > 90 } ?? false
            if !fnIsStillHeld || heldTooLong {
                self.setPressed(false)
            }
        }
        if let fnReleasePoller {
            RunLoop.main.add(fnReleasePoller, forMode: .common)
        }
    }

    private func matchesConfiguredModifiers(_ flags: CGEventFlags) -> Bool {
        let expected = settings.modifiers.reduce(CGEventFlags()) { partial, name in
            switch name.lowercased() {
            case "command", "cmd": return partial.union(.maskCommand)
            case "shift": return partial.union(.maskShift)
            case "option", "alt": return partial.union(.maskAlternate)
            case "control", "ctrl": return partial.union(.maskControl)
            case "fn": return partial.union(.maskSecondaryFn)
            default: return partial
            }
        }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        return flags.intersection(relevant) == expected
    }

}
