import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private let recorder = AudioRecorder()
    private let pill = RecordingPill()
    private let pasteInjector = PasteInjector()
    private var settings = Settings()
    private var environment: [String: String] = [:]
    private var hotkeyMonitor: HotkeyMonitor?
    private var transcriptionService: TranscriptionService?
    private var transcriptRefiner: TranscriptRefiner?
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotkeyStatusItem: NSMenuItem!
    private var pasteStatusItem: NSMenuItem!
    private var localModelStatusItem: NSMenuItem!
    private var downloadLocalModelItem: NSMenuItem!
    private var copyTranscriptItem: NSMenuItem!
    private var pasteRawTranscriptItem: NSMenuItem!
    private var verbatimItem: NSMenuItem!
    private var cleanupItems: [Int: NSMenuItem] = [:]
    private var isRecording = false
    private var isStoppingRecording = false
    private var isProcessing = false
    private var pasteTarget: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var lastRawTranscript: String?
    private var lastTranscript: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeForegroundApplications()
        loadSettings()
        configureMenuBar()
        requestPermissions()
        configureHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        hotkeyMonitor?.stop()
        if isRecording || isStoppingRecording { _ = try? recorder.stop() }
    }

    private func observeForegroundApplications() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            self?.lastExternalApplication = application
        }

        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = current
        }
    }

    private func loadSettings() {
        do {
            settings = try settingsStore.load()
        } catch {
            settings = Settings()
            NSLog("FlowDictation could not load config: %@", error.localizedDescription)
        }
        environment = DotEnv.load(from: [settingsStore.configURL.deletingLastPathComponent(), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)])
        transcriptionService = TranscriptionService(settings: settings, environment: environment)
        transcriptRefiner = TranscriptRefiner(settings: settings, environment: environment)
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Flow"
        statusItem.button?.toolTip = "Flow Dictation"

        let menu = NSMenu()
        hotkeyStatusItem = NSMenuItem(title: "Global hotkey: checking…", action: nil, keyEquivalent: "")
        hotkeyStatusItem.isEnabled = false
        menu.addItem(hotkeyStatusItem)

        pasteStatusItem = NSMenuItem(title: "Text insertion: checking…", action: nil, keyEquivalent: "")
        pasteStatusItem.isEnabled = false
        menu.addItem(pasteStatusItem)

        localModelStatusItem = NSMenuItem(title: "Local model: checking…", action: nil, keyEquivalent: "")
        localModelStatusItem.isEnabled = false
        menu.addItem(localModelStatusItem)

        downloadLocalModelItem = NSMenuItem(title: "Download Small English Model (488 MB)", action: #selector(downloadLocalModel), keyEquivalent: "")
        downloadLocalModelItem.target = self
        menu.addItem(downloadLocalModelItem)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Dictation Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        copyTranscriptItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        copyTranscriptItem.target = self
        copyTranscriptItem.isEnabled = false
        menu.addItem(copyTranscriptItem)

        pasteRawTranscriptItem = NSMenuItem(title: "Paste Raw Last Transcript", action: #selector(pasteRawLastTranscript), keyEquivalent: "")
        pasteRawTranscriptItem.target = self
        pasteRawTranscriptItem.isEnabled = false
        menu.addItem(pasteRawTranscriptItem)

        let cleanupMenuItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        cleanupMenuItem.submenu = makeCleanupMenu()
        menu.addItem(cleanupMenuItem)
        menu.addItem(.separator())

        let openSettings = NSMenuItem(title: "Open Settings File", action: #selector(openSettingsFile), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)

        let reloadSettings = NSMenuItem(title: "Reload Settings", action: #selector(reloadSettingsFile), keyEquivalent: "r")
        reloadSettings.target = self
        menu.addItem(reloadSettings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Flow Dictation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateMenuState()
        updatePastePermissionStatus()
        updateLocalModelState()
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("FlowDictation microphone permission was denied.") }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    private func configureHotkey() {
        hotkeyMonitor?.stop()
        let monitor = HotkeyMonitor(settings: settings.hotkey)
        monitor.onPress = { [weak self] in self?.beginRecording() }
        monitor.onRelease = { [weak self] in self?.finishRecording() }
        hotkeyMonitor = monitor
        if !monitor.start() {
            statusItem.button?.toolTip = "Flow Dictation needs Input Monitoring permission. See README."
            hotkeyStatusItem?.title = "Global hotkey: Input Monitoring required"
            NSLog("FlowDictation could not start the event tap; grant Input Monitoring permission.")
        } else {
            hotkeyStatusItem?.title = "Global hotkey: active (hold Fn)"
        }
    }

    private func beginRecording() {
        guard settings.enabled, !isRecording, !isStoppingRecording, !isProcessing else { return }
        do {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                pasteTarget = frontmost
                lastExternalApplication = frontmost
            } else {
                pasteTarget = lastExternalApplication
            }
            try recorder.start()
            isRecording = true
            statusItem.button?.title = "Flow *"
            pill.show()
        } catch {
            report(error)
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        pill.showTranscribing()
        statusItem.button?.title = "Flow..."
        isStoppingRecording = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            self?.stopRecordingAndTranscribe()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording, isStoppingRecording else { return }
        do {
            let recording = try recorder.stop()
            isRecording = false
            isStoppingRecording = false
            isProcessing = true
            guard let transcriptionService, let transcriptRefiner else { return }
            let delay = settings.pasteRestoreDelayMilliseconds
            let target = pasteTarget
            pasteTarget = nil
            let owner = self
            Task.detached(priority: .userInitiated) { [owner, pasteInjector] in
                defer { try? FileManager.default.removeItem(at: recording) }
                do {
                    let raw = try await transcriptionService.transcribe(file: recording)
                    let final = try await transcriptRefiner.refine(raw)
                    await MainActor.run {
                        owner.lastTranscript = final
                        owner.lastRawTranscript = raw
                        owner.copyTranscriptItem?.isEnabled = true
                        owner.pasteRawTranscriptItem?.isEnabled = true
                        pasteInjector.insert(final, into: target, restoreAfter: delay)
                        owner.completeProcessing()
                    }
                } catch {
                    await MainActor.run { owner.report(error) }
                }
            }
        } catch {
            report(error)
        }
    }

    private func completeProcessing() {
        isProcessing = false
        pill.hide()
        statusItem.button?.title = "Flow"
        updateMenuState()
        updatePastePermissionStatus()
    }

    private func report(_ error: Error) {
        NSLog("FlowDictation: %@", error.localizedDescription)
        isProcessing = false
        isRecording = false
        isStoppingRecording = false
        pill.hide()
        statusItem.button?.title = "Flow !"
        statusItem.button?.toolTip = error.localizedDescription
        updateMenuState()
        showError(error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem.button?.title = "Flow"
            self?.statusItem.button?.toolTip = "Flow Dictation"
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Dictation could not complete"
        let message = error.localizedDescription
        alert.informativeText = message.count > 700 ? String(message.prefix(700)) + "..." : message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func updatePastePermissionStatus() {
        let trusted = AXIsProcessTrusted()
        pasteStatusItem?.title = trusted
            ? "Text insertion: ready"
            : "Text insertion: Accessibility required"
    }

    private func updateLocalModelState() {
        let modelPath = SettingsStore.expand(settings.localWhisper.modelPath)
        let hasModel = FileManager.default.fileExists(atPath: modelPath)
        localModelStatusItem?.title = hasModel ? "Local model: ready" : "Local model: download required"
        downloadLocalModelItem?.title = hasModel
            ? "Small English Model Installed"
            : "Download Small English Model (488 MB)"
        downloadLocalModelItem?.isEnabled = !hasModel
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        try? settingsStore.save(settings)
        updateMenuState()
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            report(error)
        }
        updateMenuState()
    }

    @objc private func openSettingsFile() {
        NSWorkspace.shared.open(settingsStore.configURL)
    }

    @objc private func reloadSettingsFile() {
        loadSettings()
        configureHotkey()
        updateMenuState()
        updateLocalModelState()
    }

    @objc private func downloadLocalModel() {
        downloadLocalModelItem?.isEnabled = false
        downloadLocalModelItem?.title = "Downloading Small English Model…"
        Task { [weak self] in
            do {
                let modelURL = try await LocalModelManager.downloadSmallEnglishModel()
                OperationQueue.main.addOperation { [weak self] in
                    guard let self else { return }
                    self.settings.localWhisper.modelPath = modelURL.path
                    self.persistProcessingSettings()
                    self.updateLocalModelState()
                }
            } catch {
                OperationQueue.main.addOperation { [weak self] in
                    self?.updateLocalModelState()
                    self?.report(error)
                }
            }
        }
    }

    @objc private func copyLastTranscript() {
        guard let lastTranscript, !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        statusItem.button?.toolTip = "Last transcript copied"
    }

    @objc private func pasteRawLastTranscript() {
        guard let lastRawTranscript, !lastRawTranscript.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplication
            : frontmost
        pasteInjector.insert(lastRawTranscript, into: target, restoreAfter: settings.pasteRestoreDelayMilliseconds)
    }

    private func makeCleanupMenu() -> NSMenu {
        let menu = NSMenu()
        verbatimItem = NSMenuItem(title: "Verbatim Mode", action: #selector(toggleVerbatimMode), keyEquivalent: "")
        verbatimItem.target = self
        menu.addItem(verbatimItem)
        menu.addItem(.separator())
        addCleanupItem(to: menu, title: "Remove Fillers", tag: 1)
        addCleanupItem(to: menu, title: "Resolve Retractions", tag: 2)
        addCleanupItem(to: menu, title: "Hinglish Grammar", tag: 3)
        addCleanupItem(to: menu, title: "Format Spoken Lists", tag: 4)
        addCleanupItem(to: menu, title: "Numbers and Punctuation", tag: 5)
        addCleanupItem(to: menu, title: "Paragraphs From Pauses", tag: 6)
        addCleanupItem(to: menu, title: "Skip LLM for Simple Clips", tag: 7)
        return menu
    }

    private func addCleanupItem(to menu: NSMenu, title: String, tag: Int) {
        let item = NSMenuItem(title: title, action: #selector(toggleCleanupFeature), keyEquivalent: "")
        item.tag = tag
        item.target = self
        cleanupItems[tag] = item
        menu.addItem(item)
    }

    @objc private func toggleVerbatimMode() {
        settings.cleanup.verbatimMode.toggle()
        persistProcessingSettings()
    }

    @objc private func toggleCleanupFeature(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: settings.cleanup.removeFillers.toggle()
        case 2: settings.cleanup.resolveRetractions.toggle()
        case 3: settings.cleanup.improveHinglish.toggle()
        case 4: settings.cleanup.formatLists.toggle()
        case 5: settings.cleanup.deterministicFormatting.toggle()
        case 6: settings.cleanup.paragraphBreaksFromPauses.toggle()
        case 7: settings.cleanup.skipLLMForSimpleClips.toggle()
        default: return
        }
        persistProcessingSettings()
    }

    private func persistProcessingSettings() {
        try? settingsStore.save(settings)
        transcriptionService = TranscriptionService(settings: settings, environment: environment)
        transcriptRefiner = TranscriptRefiner(settings: settings, environment: environment)
        updateMenuState()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateMenuState() {
        enabledItem?.state = settings.enabled ? .on : .off
        enabledItem?.title = settings.enabled ? "Dictation Enabled" : "Dictation Disabled"
        verbatimItem?.state = settings.cleanup.verbatimMode ? .on : .off
        cleanupItems[1]?.state = settings.cleanup.removeFillers ? .on : .off
        cleanupItems[2]?.state = settings.cleanup.resolveRetractions ? .on : .off
        cleanupItems[3]?.state = settings.cleanup.improveHinglish ? .on : .off
        cleanupItems[4]?.state = settings.cleanup.formatLists ? .on : .off
        cleanupItems[5]?.state = settings.cleanup.deterministicFormatting ? .on : .off
        cleanupItems[6]?.state = settings.cleanup.paragraphBreaksFromPauses ? .on : .off
        cleanupItems[7]?.state = settings.cleanup.skipLLMForSimpleClips ? .on : .off
        if #available(macOS 13.0, *) {
            loginItem?.isEnabled = true
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem?.isEnabled = false
        }
    }
}
