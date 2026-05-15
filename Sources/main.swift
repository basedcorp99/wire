import AppKit
import Carbon
import WebKit
import AVFoundation
import CoreAudio
import AudioToolbox
import IOKit.hid
import MediaPlayer
import ApplicationServices
import ServiceManagement

// MARK: - Entry point

@main
struct WireApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Launch at Login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Launch at login enabled"
        case .requiresApproval:
            return "Approve wire in System Settings → Login Items"
        case .notRegistered:
            return "Launch at login disabled"
        case .notFound:
            return "Install wire to /Applications first"
        @unknown default:
            return "Launch at login status unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let sendEnterAfterPasteDefaultsKey = "sendEnterAfterPaste"
    private static let headsetControlsEnabledDefaultsKey = "headsetControlsEnabled"
    private static let computerControlsEnabledDefaultsKey = "computerControlsEnabled"
    private static let computerAutoEnableEnabledDefaultsKey = "computerAutoEnableEnabled"
    private static let computerAutoEnablePhraseDefaultsKey = "computerAutoEnablePhrase"
    private static let computerCustomHarnessEnabledDefaultsKey = "computerCustomHarnessEnabled"
    private static let computerHarnessCommandDefaultsKey = "computerHarnessCommand"
    private static let defaultComputerHarnessCommand = "codex --yolo -c 'model_reasoning_effort=\"low\"' e {{prompt}}"

    private let state = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyManager: HotKeyManager!
    private var headsetProbeManager: HeadsetProbeManager!
    private var codexClient: CodexAPIClient!
    private var recorder: AudioRecorder!
    private var statusSpinnerTimer: Timer?
    private var recordingStatusTimer: Timer?
    private var menuBarFeedbackClearWorkItem: DispatchWorkItem?
    private var menuBarFeedbackTitle: String?
    private var popoverOutsideClickMonitors: [Any] = []
    private var recordingStartedAt: Date?
    private var activeRecordingShouldPressReturn = false
    private var activeRecordingStartedByAirPods = false
    private var statusSpinnerIndex = 0
    private var activeRecordingKind: HotKeyKind?
    private let statusSpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state.sendEnterAfterPaste = UserDefaults.standard.bool(forKey: Self.sendEnterAfterPasteDefaultsKey)
        state.headsetControlsEnabled = (UserDefaults.standard.object(forKey: Self.headsetControlsEnabledDefaultsKey) as? Bool) ?? true
        state.computerControlsEnabled = UserDefaults.standard.bool(forKey: Self.computerControlsEnabledDefaultsKey)
        state.computerAutoEnableEnabled = UserDefaults.standard.bool(forKey: Self.computerAutoEnableEnabledDefaultsKey)
        state.computerAutoEnablePhrase = UserDefaults.standard.string(forKey: Self.computerAutoEnablePhraseDefaultsKey) ?? ""
        state.computerCustomHarnessEnabled = UserDefaults.standard.bool(forKey: Self.computerCustomHarnessEnabledDefaultsKey)
        state.computerHarnessCommand = UserDefaults.standard.string(forKey: Self.computerHarnessCommandDefaultsKey) ?? Self.defaultComputerHarnessCommand

        // Initialize components
        codexClient = CodexAPIClient()
        recorder = AudioRecorder()
        headsetProbeManager = HeadsetProbeManager(
            state: state,
            onTogglePressed: { [weak self] in self?.handleHeadsetTogglePressed() },
            onAirPodsTogglePressed: { [weak self] in self?.handleAirPodsTogglePressed() },
            onHoldPressed: { [weak self] in self?.handleHeadsetHoldPressed() },
            onHoldReleased: { [weak self] in self?.handleHeadsetHoldReleased() },
            isRecording: { [weak self] in self?.recorder.hasActiveRecording ?? false }
        )
        hotKeyManager = HotKeyManager(
            state: state,
            onTogglePressed: { [weak self] in self?.handleToggleHotKeyPressed() },
            onHoldPressed: { [weak self] in self?.handleHoldHotKeyPressed() },
            onHoldReleased: { [weak self] in self?.handleHoldHotKeyReleased() }
        )

        // Setup menu bar: icon only
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "wire") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeft
        } else {
            statusItem.button?.title = "🎙"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        // Setup popover
        let controller = PopoverViewController(
            state: state,
            hotKeyManager: hotKeyManager,
            headsetProbeManager: headsetProbeManager
        )
        _ = controller.view
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller

        state.onChange = { [weak self, weak controller] in
            self?.renderStatusItem()
            controller?.refresh()
        }
        hotKeyManager.registerSavedShortcuts()
        headsetProbeManager.restoreSavedState()
        headsetProbeManager.setControlsEnabled(state.headsetControlsEnabled)
        if SMAppService.mainApp.status == .notRegistered {
            try? LaunchAtLogin.setEnabled(true)
        }
        scheduleInitialAccessibilityCheck()
        scheduleInitialMicrophoneCheck()

        // Pre-warm the API client and check auth
        Task {
            await initializeSession()
        }
        runAirPodsCaptureSelfTestIfRequested()
    }

    private func runAirPodsCaptureSelfTestIfRequested() {
        guard let rawSeconds = ProcessInfo.processInfo.environment["WIRE_SELF_TEST_AIRPODS_CAPTURE_SECONDS"],
              let seconds = Double(rawSeconds) else { return }
        let outputURL = URL(fileURLWithPath: "/tmp/wire-airpods-capture-self-test.txt")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            handleAirPodsTogglePressed()

            let startDeadline = Date().addingTimeInterval(3)
            while !recorder.hasActiveRecording && Date() < startDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard recorder.hasActiveRecording else {
                try? "started=false\nstatus=\(state.statusText)\n".write(to: outputURL, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(max(0.2, seconds) * 1_000_000_000))
            let data = recorder.stop()
            stopRecordingStatusTimer()
            activeRecordingKind = nil
            activeRecordingShouldPressReturn = false
            activeRecordingStartedByAirPods = false
            state.isBusy = false
            state.transcriptionStage = .idle

            let summary: String
            if let data, let stats = wavStats(data) {
                summary = """
                started=true
                bytes=\(data.count)
                duration=\(String(format: "%.3f", stats.duration))
                rms=\(String(format: "%.1f", stats.rms))
                peak=\(stats.peak)

                """
            } else {
                summary = "started=true\nbytes=\(data?.count ?? 0)\nduration=0.000\nrms=0.0\npeak=0\n"
            }
            try? summary.write(to: outputURL, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func initializeSession() async {
        await MainActor.run {
            state.statusText = "Initializing session..."
        }
        do {
            try await codexClient.prepare()

            if let selfTestPath = ProcessInfo.processInfo.environment["WIRE_SELF_TEST_AUDIO"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: selfTestPath))
                print("WIRE_SELF_TEST_AUDIO_BYTES=\(data.count)")
                let text = try await codexClient.transcribe(audioData: data)
                print("WIRE_SELF_TEST_RESULT=\(text)")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }

            await MainActor.run {
                state.statusText = "Ready. Press shortcut to transcribe."
            }
        } catch {
            await MainActor.run {
                state.statusText = "Failed: \(error.localizedDescription)"
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            }
            installPopoverOutsideClickMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removePopoverOutsideClickMonitor()
    }

    private func installPopoverOutsideClickMonitor() {
        removePopoverOutsideClickMonitor()
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopoverIfMouseIsOutside()
            }
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverIfMouseIsOutside()
            return event
        }
        popoverOutsideClickMonitors = [globalMonitor, localMonitor].compactMap { $0 }
    }

    private func removePopoverOutsideClickMonitor() {
        for monitor in popoverOutsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        popoverOutsideClickMonitors.removeAll()
    }

    private func closePopoverIfMouseIsOutside() {
        guard popover.isShown else {
            removePopoverOutsideClickMonitor()
            return
        }
        guard let popoverWindow = popover.contentViewController?.view.window else {
            closePopover()
            return
        }
        let screenPoint = NSEvent.mouseLocation
        guard popoverWindow.frame.contains(screenPoint) else {
            closePopover()
            return
        }
    }

    private func renderStatusItem() {
        DispatchQueue.main.async {
            let isTranscribing = self.state.transcriptionStage == .transcribing
            if let image = NSImage(systemSymbolName: self.recorder.hasActiveRecording ? "mic.circle.fill" : "mic.fill", accessibilityDescription: "wire") {
                image.isTemplate = true
                self.statusItem.button?.image = image
                self.statusItem.button?.imagePosition = .imageLeft
            }
            if isTranscribing {
                self.startStatusSpinner()
            } else if self.recorder.hasActiveRecording {
                self.stopStatusSpinner()
                self.updateRecordingStatusTitle()
            } else if let menuBarFeedbackTitle = self.menuBarFeedbackTitle {
                self.stopStatusSpinner()
                self.statusItem.button?.title = " " + menuBarFeedbackTitle
            } else {
                self.stopStatusSpinner()
                self.statusItem.button?.title = ""
            }
        }
    }

    private func startStatusSpinner() {
        guard statusSpinnerTimer == nil else { return }
        statusSpinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusSpinnerIndex = (self.statusSpinnerIndex + 1) % self.statusSpinnerFrames.count
            self.statusItem.button?.title = " " + self.statusSpinnerFrames[self.statusSpinnerIndex]
        }
        statusSpinnerTimer?.fire()
    }

    private func stopStatusSpinner() {
        statusSpinnerTimer?.invalidate()
        statusSpinnerTimer = nil
        statusSpinnerIndex = 0
    }

    private func startRecordingStatusTimer() {
        recordingStartedAt = Date()
        updateRecordingStatusTitle()
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRecordingStatusTitle()
        }
    }

    private func stopRecordingStatusTimer() {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
        recordingStartedAt = nil
    }

    private func showMenuBarFeedback(_ title: String, duration: TimeInterval = 1.4) {
        menuBarFeedbackClearWorkItem?.cancel()
        menuBarFeedbackTitle = title
        renderStatusItem()

        let clearWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.menuBarFeedbackTitle == title else { return }
            self.menuBarFeedbackTitle = nil
            self.renderStatusItem()
        }
        menuBarFeedbackClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: clearWorkItem)
    }

    private func updateRecordingStatusTitle() {
        guard let recordingStartedAt else {
            statusItem.button?.title = ""
            return
        }

        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        statusItem.button?.title = String(format: " REC %d:%02d", minutes, seconds)
    }

    private func handleToggleHotKeyPressed() {
        handleTranscribe()
    }

    private func handleHeadsetTogglePressed() {
        handleTranscribe(sendReturnAfterPasteEligible: true)
    }

    private func handleAirPodsTogglePressed() {
        handleTranscribe(useBuiltInInput: true, sendReturnAfterPasteEligible: true, startedByAirPods: true)
    }

    private func handleHoldHotKeyPressed() {
        startRecording(status: "Recording… release hold shortcut to transcribe", kind: .hold)
    }

    private func handleHeadsetHoldPressed() {
        startRecording(status: "Recording… release headset button to transcribe", kind: .hold, sendReturnAfterPasteEligible: true)
    }

    private func handleHoldHotKeyReleased() {
        guard recorder.hasActiveRecording, activeRecordingKind == .hold else { return }
        stopAndTranscribe()
    }

    private func handleHeadsetHoldReleased() {
        handleHoldHotKeyReleased()
    }

    private func handleTranscribe(
        useBuiltInInput: Bool = false,
        sendReturnAfterPasteEligible: Bool = false,
        startedByAirPods: Bool = false
    ) {
        if recorder.hasActiveRecording {
            stopAndTranscribe()
        } else {
            startRecording(
                status: "Recording… press toggle shortcut again to stop",
                kind: .toggle,
                useBuiltInInput: useBuiltInInput,
                sendReturnAfterPasteEligible: sendReturnAfterPasteEligible,
                startedByAirPods: startedByAirPods
            )
        }
    }

    private func startRecording(
        status: String,
        kind: HotKeyKind,
        useBuiltInInput: Bool = false,
        sendReturnAfterPasteEligible: Bool = false,
        startedByAirPods: Bool = false
    ) {
        Task { @MainActor in
            guard !recorder.hasActiveRecording else { return }
            guard state.transcriptionStage != .transcribing else { return }

            guard await ensureMicrophonePermission() else {
                state.statusText = "Enable Microphone permission for wire"
                state.transcriptionStage = .error("Microphone permission missing")
                state.isBusy = false
                openMicrophoneSettings()
                return
            }

            state.lastTranscription = ""
            state.transcriptionStage = .recording
            state.statusText = status
            state.isBusy = true

            var inputDeviceID: AudioDeviceID?
            do {
                if useBuiltInInput {
                    inputDeviceID = try DefaultAudioInputOverride.builtInInputDeviceID()
                }
                try recorder.start(inputDeviceID: inputDeviceID)
                activeRecordingKind = kind
                activeRecordingShouldPressReturn = sendReturnAfterPasteEligible
                activeRecordingStartedByAirPods = startedByAirPods
                startRecordingStatusTimer()
            } catch {
                state.statusText = "Could not start recording: \(error.localizedDescription)"
                state.transcriptionStage = .error(error.localizedDescription)
                state.isBusy = false
            }
        }
    }

    private func stopAndTranscribe() {
        Task { @MainActor in
            guard recorder.hasActiveRecording else { return }
            state.statusText = "Loading… transcribing"
            state.transcriptionStage = .transcribing

            let audioData = recorder.stop()
            let shouldPressReturnAfterPaste = activeRecordingShouldPressReturn && state.sendEnterAfterPaste
            let wasStartedByAirPods = activeRecordingStartedByAirPods
            stopRecordingStatusTimer()
            activeRecordingKind = nil
            activeRecordingShouldPressReturn = false
            activeRecordingStartedByAirPods = false

            guard let data = audioData, data.count > 1000 else {
                state.statusText = "Recording too short, try again"
                state.transcriptionStage = .error("Recording too short")
                state.isBusy = false
                return
            }

            guard hasCapturedAudio(data) else {
                state.statusText = "No microphone audio captured"
                state.transcriptionStage = .error("No microphone audio captured")
                state.isBusy = false
                return
            }

            guard wasStartedByAirPods || isLikelySpeechRecording(data) else {
                state.statusText = "Ready"
                state.transcriptionStage = .idle
                state.isBusy = false
                return
            }

            state.statusText = "Loading… uploading \(data.count / 1024) KB"

            do {
                let text = try await transcribe(data, retryASRFailure: wasStartedByAirPods)

                state.lastTranscription = text
                state.transcriptionStage = .done
                state.statusText = "Done"

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                if !handleComputerTranscript(text) {
                    typeText(text, pressReturnAfterPaste: shouldPressReturnAfterPaste)
                }
            } catch {
                if isASRBackendFailure(error) {
                    state.statusText = "Error: speech recognition failed. Try again."
                    state.transcriptionStage = .error("Speech recognition failed")
                } else {
                    state.statusText = "Error: \(error.localizedDescription)"
                    state.transcriptionStage = .error(error.localizedDescription)
                }
            }
            state.isBusy = false
        }
    }

    private func transcribe(_ data: Data, retryASRFailure: Bool) async throws -> String {
        do {
            return try await codexClient.transcribe(audioData: data)
        } catch {
            guard retryASRFailure, isASRBackendFailure(error) else {
                throw error
            }
            await MainActor.run {
                state.statusText = "Speech recognition failed, retrying..."
            }
            try await Task.sleep(nanoseconds: 800_000_000)
            return try await codexClient.transcribe(audioData: data)
        }
    }

    private func isASRBackendFailure(_ error: Error) -> Bool {
        guard case AppError.transcriptionFailed(let message) = error else { return false }
        return message.contains("HTTP 500") && message.localizedCaseInsensitiveContains("ASR")
    }

    @discardableResult
    private func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func scheduleInitialAccessibilityCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.openAccessibilitySettingsOnceIfNeeded()
        }
    }

    private func openAccessibilitySettingsOnceIfNeeded() {
        guard !requestAccessibilityPermission(prompt: false) else { return }
        let key = "didOpenAccessibilitySettings.wireExecutable"
        guard !UserDefaults.standard.bool(forKey: key) else {
            state.statusText = "Enable Accessibility permission for wire to paste"
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        state.statusText = "Enable Accessibility permission for wire to paste"
        openAccessibilitySettings()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleInitialMicrophoneCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.requestMicrophonePermissionIfNeeded()
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermissionIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.state.statusText = granted ? "Microphone ready" : "Enable Microphone permission for wire"
                    if !granted { self?.openMicrophoneSettings() }
                }
            }
        case .denied, .restricted:
            state.statusText = "Enable Microphone permission for wire"
            openMicrophoneSettings()
        @unknown default:
            state.statusText = "Enable Microphone permission for wire"
            openMicrophoneSettings()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isLikelySpeechRecording(_ data: Data) -> Bool {
        guard let stats = wavStats(data) else {
            return data.count > 18_000
        }

        // Ignore accidental taps / empty push-to-talk releases. A 16 kHz mono
        // 16-bit WAV is about 32 KB/sec plus header.
        if stats.duration < 0.6 { return false }
        if stats.duration < 1.5 && stats.peak < 700 { return false }
        if stats.rms < 90 && stats.peak < 900 { return false }
        return true
    }

    private func hasCapturedAudio(_ data: Data) -> Bool {
        guard let stats = wavStats(data) else {
            return data.count > 18_000
        }
        return stats.duration > 0.1
    }

    private func wavStats(_ data: Data) -> (duration: Double, rms: Double, peak: Int)? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        var offset = 12
        var sampleRate = 16_000
        var channels = 1
        var bitsPerSample = 16
        var dataStart: Int?
        var dataSize: Int?

        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(bytes[offset + 4]) | (Int(bytes[offset + 5]) << 8) | (Int(bytes[offset + 6]) << 16) | (Int(bytes[offset + 7]) << 24)
            let chunkStart = offset + 8
            if chunkStart + size > bytes.count { break }

            if chunkID == "fmt " && size >= 16 {
                channels = Int(bytes[chunkStart + 2]) | (Int(bytes[chunkStart + 3]) << 8)
                sampleRate = Int(bytes[chunkStart + 4]) | (Int(bytes[chunkStart + 5]) << 8) | (Int(bytes[chunkStart + 6]) << 16) | (Int(bytes[chunkStart + 7]) << 24)
                bitsPerSample = Int(bytes[chunkStart + 14]) | (Int(bytes[chunkStart + 15]) << 8)
            } else if chunkID == "data" {
                dataStart = chunkStart
                dataSize = size
                break
            }
            offset = chunkStart + size + (size % 2)
        }

        guard bitsPerSample == 16,
              let dataStart,
              let dataSize,
              dataSize > 1,
              sampleRate > 0,
              channels > 0 else { return nil }

        let end = min(dataStart + dataSize, bytes.count)
        var i = dataStart
        var sumSquares = 0.0
        var peak = 0
        var samples = 0
        while i + 1 < end {
            let unsigned = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            let sample = Int(Int16(bitPattern: unsigned))
            let absSample = abs(sample)
            if absSample > peak { peak = absSample }
            sumSquares += Double(sample * sample)
            samples += 1
            i += 2
        }
        guard samples > 0 else { return nil }
        let duration = Double(samples) / Double(sampleRate * channels)
        let rms = sqrt(sumSquares / Double(samples))
        return (duration, rms, peak)
    }

    private func typeText(_ text: String, pressReturnAfterPaste: Bool) {
        guard requestAccessibilityPermission(prompt: false) else {
            state.statusText = "Enable Accessibility permission for wire to paste"
            openAccessibilitySettings()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Paste using Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if pressReturnAfterPaste {
            releaseCommandKeys(source: source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.pressReturnKey()
            }
        }
    }

    private func handleComputerTranscript(_ text: String) -> Bool {
        if !state.computerControlsEnabled {
            let phrase = state.computerAutoEnablePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.computerAutoEnableEnabled,
                  normalizedPhrase(phrase).split(separator: " ").count >= 2,
                  fuzzyMatches(text, phrase) else { return false }
            setComputerControlsEnabled(true)
            state.statusText = "Computer mode enabled"
            showMenuBarFeedback("Mode on")
            return true
        }

        executeComputerPrompt(text)
        return true
    }

    private func executeComputerPrompt(_ prompt: String) {
        guard !state.computerCommandRunning else {
            state.statusText = "Codex is already running"
            return
        }

        state.computerCommandRunning = true
        let usesCustomHarness = state.computerCustomHarnessEnabled && !state.computerHarnessCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        state.statusText = usesCustomHarness ? "Running harness..." : "Running codex..."

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", renderedHarnessCommand(for: prompt)]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let captureQueue = DispatchQueue(label: "wire.codex-command-capture")
        var stdoutData = Data()
        var stderrData = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            captureQueue.async {
                stdoutData.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            captureQueue.async {
                stderrData.append(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            captureQueue.async {
                stdoutData.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                stderrData.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    self?.state.computerCommandRunning = false
                    if usesCustomHarness {
                        self?.state.statusText = status == 0 ? "Harness finished" : "Harness exited \(status)"
                    } else {
                        self?.state.statusText = status == 0 ? "Codex finished" : "Codex exited \(status)"
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            state.computerCommandRunning = false
            state.statusText = usesCustomHarness
                ? "Could not run harness: \(error.localizedDescription)"
                : "Could not run Codex: \(error.localizedDescription)"
            state.transcriptionStage = .error(error.localizedDescription)
        }
    }

    private func renderedHarnessCommand(for prompt: String) -> String {
        let customCommand = state.computerHarnessCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = state.computerCustomHarnessEnabled && !customCommand.isEmpty
            ? state.computerHarnessCommand
            : Self.defaultComputerHarnessCommand
        let escapedPrompt = shellSingleQuoted(prompt)

        if template.contains("{{prompt}}") {
            return template.replacingOccurrences(of: "{{prompt}}", with: escapedPrompt)
        }
        return "\(template) \(escapedPrompt)"
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func fuzzyMatches(_ transcript: String, _ phrase: String) -> Bool {
        let source = normalizedPhrase(transcript)
        let target = normalizedPhrase(phrase)
        guard !source.isEmpty, !target.isEmpty else { return false }
        if source == target || source.contains(target) || target.contains(source) {
            return true
        }

        let distance = levenshteinDistance(source, target)
        let maxLength = max(source.count, target.count)
        guard maxLength > 0 else { return false }
        let similarity = 1.0 - (Double(distance) / Double(maxLength))
        return similarity >= 0.82
    }

    private func normalizedPhrase(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }

    func setHeadsetControlsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.headsetControlsEnabledDefaultsKey)
        state.headsetControlsEnabled = enabled
        headsetProbeManager.setControlsEnabled(enabled)
        state.statusText = enabled ? "Headset controls enabled" : "Headset controls disabled"
    }

    func setSendEnterAfterPaste(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.sendEnterAfterPasteDefaultsKey)
        state.sendEnterAfterPaste = enabled
        state.statusText = enabled ? "Headset recordings will press Return after pasting" : "Return after paste disabled"
    }

    func setComputerControlsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.computerControlsEnabledDefaultsKey)
        state.computerControlsEnabled = enabled
        state.statusText = enabled ? "Computer mode enabled" : "Computer mode disabled"
    }

    func setComputerAutoEnableEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.computerAutoEnableEnabledDefaultsKey)
        state.computerAutoEnableEnabled = enabled
        state.statusText = enabled ? "Auto enable enabled" : "Auto enable disabled"
    }

    func setComputerAutoEnablePhrase(_ phrase: String) {
        UserDefaults.standard.set(phrase, forKey: Self.computerAutoEnablePhraseDefaultsKey)
        state.computerAutoEnablePhrase = phrase
        state.statusText = phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Auto enable phrase cleared"
            : "Auto enable phrase saved"
    }

    func setComputerCustomHarnessEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.computerCustomHarnessEnabledDefaultsKey)
        state.computerCustomHarnessEnabled = enabled
        state.statusText = enabled ? "Custom harness enabled" : "Custom harness disabled"
    }

    func setComputerHarnessCommand(_ command: String) {
        UserDefaults.standard.set(command, forKey: Self.computerHarnessCommandDefaultsKey)
        state.computerHarnessCommand = command
        state.statusText = "Harness saved"
    }

    private func pressReturnKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let returnKey = CGKeyCode(kVK_Return)
        let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func releaseCommandKeys(source: CGEventSource?) {
        for keyCode in [CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)] {
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - App State

enum TranscriptionStage: Equatable {
    case idle
    case recording
    case transcribing
    case done
    case error(String)
}

final class AppState {
    var onChange: (() -> Void)?

    var isBusy = false { didSet { onChange?() } }
    var statusText = "" { didSet { onChange?() } }
    var lastTranscription = "" { didSet { onChange?() } }
    var transcriptionStage: TranscriptionStage = .idle { didSet { onChange?() } }
    var sendEnterAfterPaste = false { didSet { onChange?() } }
    var headsetControlsEnabled = true { didSet { onChange?() } }
    var computerControlsEnabled = false { didSet { onChange?() } }
    var computerAutoEnableEnabled = false { didSet { onChange?() } }
    var computerAutoEnablePhrase = "" { didSet { onChange?() } }
    var computerCustomHarnessEnabled = false { didSet { onChange?() } }
    var computerHarnessCommand = "" { didSet { onChange?() } }
    var computerCommandRunning = false { didSet { onChange?() } }
}

// MARK: - Headset Controls

final class DefaultAudioInputOverride {
    private let previousDeviceID: AudioDeviceID
    private let replacementDeviceID: AudioDeviceID
    var activeDeviceID: AudioDeviceID { replacementDeviceID }

    private init(previousDeviceID: AudioDeviceID, replacementDeviceID: AudioDeviceID) {
        self.previousDeviceID = previousDeviceID
        self.replacementDeviceID = replacementDeviceID
    }

    static func activateBuiltInInput() throws -> DefaultAudioInputOverride {
        guard let previous = defaultInputDeviceID() else {
            throw AppError.transcriptionFailed("Could not read current input device")
        }
        let builtIn = try builtInInputDeviceID()
        guard previous != builtIn else {
            return DefaultAudioInputOverride(previousDeviceID: previous, replacementDeviceID: builtIn)
        }
        try setDefaultInputDeviceID(builtIn)
        return DefaultAudioInputOverride(previousDeviceID: previous, replacementDeviceID: builtIn)
    }

    func restore() {
        guard previousDeviceID != replacementDeviceID else { return }
        try? Self.setDefaultInputDeviceID(previousDeviceID)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableDeviceID
        )
        guard status == noErr else {
            throw AppError.transcriptionFailed("Could not switch input device: \(status)")
        }
    }

    static func builtInInputDeviceID() throws -> AudioDeviceID {
        guard let deviceID = audioDeviceIDs().first(where: { deviceID in
            audioStreamCount(deviceID, scope: kAudioDevicePropertyScopeInput) > 0
                && isBuiltInInput(deviceID)
        }) else {
            throw AppError.transcriptionFailed("Could not find built-in Mac microphone")
        }
        return deviceID
    }

    static func builtInInputDeviceUID() throws -> String {
        let deviceID = try builtInInputDeviceID()
        guard let uid = audioDeviceUID(deviceID) else {
            throw AppError.transcriptionFailed("Could not read Mac microphone device UID")
        }
        return uid
    }

    static func builtInInputDeviceName() throws -> String {
        audioDeviceName(try builtInInputDeviceID()) ?? "Built-in Mac microphone"
    }

    private static func isBuiltInInput(_ deviceID: AudioDeviceID) -> Bool {
        let name = (audioDeviceName(deviceID) ?? "").lowercased()
        if name.contains("macbook") || name.contains("built-in") || name.contains("built in") {
            return true
        }
        return audioTransport(deviceID) == kAudioDeviceTransportTypeBuiltIn
    }

    private static func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private static func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func audioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeUnretainedValue() as String
    }

    private static func audioTransport(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    private static func audioStreamCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return 0
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

enum HeadsetButtonMode: Int, CaseIterable {
    case longPressHold = 0
    case longPressToggle = 1

    var title: String {
        switch self {
        case .longPressHold: return "Long hold to dictate"
        case .longPressToggle: return "Long press to toggle"
        }
    }

    var statusText: String {
        switch self {
        case .longPressHold: return "Wired button: hold to dictate"
        case .longPressToggle: return "Wired button: press to toggle"
        }
    }

    var controlsWiredRecording: Bool { true }
}

final class HeadsetProbeManager {
    private struct RemoteCommandTarget {
        let command: MPRemoteCommand
        let target: Any
    }

    private static let modeDefaultsKey = "headsetButtonMode"
    private static let airPodsControlDefaultsKey = "airPodsMacMicControlEnabled"
    private static let playPauseUsage: UInt32 = 0xcd
    private static let nextTrackUsage: UInt32 = 0xb5
    private static let longPressThreshold: TimeInterval = 0.45

    private let state: AppState
    private let onTogglePressed: () -> Void
    private let onAirPodsTogglePressed: () -> Void
    private let onHoldPressed: () -> Void
    private let onHoldReleased: () -> Void
    private let isRecording: () -> Bool
    private var hidManager: IOHIDManager?
    private var remoteCommandTargets: [RemoteCommandTarget] = []
    private var airPodsProbeEngine: AVAudioEngine?
    private var airPodsProbePlayer: AVAudioPlayerNode?
    private var airPodsNowPlayingTimer: Timer?
    private var mode: HeadsetButtonMode = .longPressHold
    private var controlsEnabled = true
    private var airPodsControlEnabled = false
    private var lastAirPodsToggleAt: Date?
    private var headsetPressStartedAt: Date?
    private var longPressWorkItem: DispatchWorkItem?
    private var longPressActive = false

    private static func appendAirPodsDebugLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/wire-airpods-remote.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    init(
        state: AppState,
        onTogglePressed: @escaping () -> Void,
        onAirPodsTogglePressed: @escaping () -> Void,
        onHoldPressed: @escaping () -> Void,
        onHoldReleased: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.state = state
        self.onTogglePressed = onTogglePressed
        self.onAirPodsTogglePressed = onAirPodsTogglePressed
        self.onHoldPressed = onHoldPressed
        self.onHoldReleased = onHoldReleased
        self.isRecording = isRecording
    }

    deinit {
        stop()
    }

    var currentMode: HeadsetButtonMode { mode }
    var areControlsEnabled: Bool { controlsEnabled }
    var isAirPodsControlEnabled: Bool { airPodsControlEnabled }

    func restoreSavedState() {
        let defaults = UserDefaults.standard
        let rawMode = defaults.object(forKey: Self.modeDefaultsKey) as? Int
        let migratedAirPodsEnabled = rawMode == 5
        let savedMode: HeadsetButtonMode
        switch rawMode {
        case HeadsetButtonMode.longPressToggle.rawValue, 3:
            savedMode = .longPressToggle
        default:
            savedMode = .longPressHold
        }
        let savedAirPodsEnabled = (defaults.object(forKey: Self.airPodsControlDefaultsKey) as? Bool) ?? migratedAirPodsEnabled

        setMode(savedMode, persist: false)
        setAirPodsControlEnabled(savedAirPodsEnabled, persist: false)
    }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setMode(_ mode: HeadsetButtonMode) {
        setMode(mode, persist: true)
    }

    func setAirPodsControlEnabled(_ enabled: Bool) {
        setAirPodsControlEnabled(enabled, persist: true)
    }

    private func setMode(_ mode: HeadsetButtonMode, persist: Bool) {
        if persist {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        }
        cancelPendingLongPress()
        self.mode = mode
        if controlsEnabled {
            start()
        }
        state.statusText = mode.statusText
    }

    private func setAirPodsControlEnabled(_ enabled: Bool, persist: Bool) {
        if persist {
            UserDefaults.standard.set(enabled, forKey: Self.airPodsControlDefaultsKey)
        }
        airPodsControlEnabled = enabled
        syncRemoteCommandProbe()
        if persist {
            state.statusText = enabled ? "Experimental AirPods enabled" : "Experimental AirPods disabled"
        }
    }

    func start() {
        guard controlsEnabled else { return }
        installHIDControl()
        syncRemoteCommandProbe()
    }

    func stop() {
        cancelPendingLongPress()
        removeRemoteCommandProbe()
        removeHIDControl()
    }

    private func installHIDControl() {
        guard hidManager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_SystemControl
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let manager = Unmanaged<HeadsetProbeManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleHIDValue(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        IOHIDManagerOpen(manager, openOptions)
        hidManager = manager
    }

    private func removeHIDControl() {
        guard let hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
    }

    private func syncRemoteCommandProbe() {
        if controlsEnabled && airPodsControlEnabled {
            installRemoteCommandProbe()
        } else {
            removeRemoteCommandProbe()
        }
    }

    private func installRemoteCommandProbe() {
        guard remoteCommandTargets.isEmpty else { return }
        startSilentAirPodsProbeAudio()
        publishAirPodsProbeNowPlaying()
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("remote play", center.playCommand),
            ("remote pause", center.pauseCommand),
            ("remote togglePlayPause", center.togglePlayPauseCommand),
            ("remote stop", center.stopCommand),
            ("remote nextTrack", center.nextTrackCommand),
            ("remote previousTrack", center.previousTrackCommand),
            ("remote skipForward", center.skipForwardCommand),
            ("remote skipBackward", center.skipBackwardCommand),
            ("remote seekForward", center.seekForwardCommand),
            ("remote seekBackward", center.seekBackwardCommand)
        ]

        for (label, command) in commands {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                self?.logRemoteCommand(label, event: event)
                return .success
            }
            remoteCommandTargets.append(RemoteCommandTarget(command: command, target: target))
        }
        startAirPodsNowPlayingTimer()
    }

    private func removeRemoteCommandProbe() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
            target.command.isEnabled = false
        }
        remoteCommandTargets.removeAll()
        stopAirPodsNowPlayingTimer()
        stopSilentAirPodsProbeAudio()
        clearAirPodsProbeNowPlaying()
    }

    private func logRemoteCommand(_ label: String, event: MPRemoteCommandEvent) {
        Self.appendAirPodsDebugLog("mp label=\(label) recording=\(isRecording())")
        refreshAirPodsRemoteTarget()
        handleAirPodsRemoteCommand(label)
    }

    private func handleAirPodsRemoteCommand(_ label: String) {
        guard airPodsControlEnabled else {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=disabled")
            return
        }
        let recording = isRecording()
        if recording {
            Self.appendAirPodsDebugLog("accept-stop label=\(label)")
        } else {
            guard label == "remote nextTrack" || label == "hid nextTrack" else {
                Self.appendAirPodsDebugLog("ignored label=\(label) recording=false reason=not-start-command")
                return
            }
        }
        if let lastAirPodsToggleAt, Date().timeIntervalSince(lastAirPodsToggleAt) < 0.45 {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=debounce")
            return
        }
        lastAirPodsToggleAt = Date()
        Self.appendAirPodsDebugLog("toggle label=\(label) recordingBefore=\(recording)")
        DispatchQueue.main.async { [onAirPodsTogglePressed] in
            onAirPodsTogglePressed()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshAirPodsRemoteTarget()
        }
    }

    private func startAirPodsNowPlayingTimer() {
        stopAirPodsNowPlayingTimer()
        airPodsNowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshAirPodsRemoteTarget()
        }
    }

    private func stopAirPodsNowPlayingTimer() {
        airPodsNowPlayingTimer?.invalidate()
        airPodsNowPlayingTimer = nil
    }

    private func refreshAirPodsRemoteTarget() {
        ensureSilentAirPodsProbeAudio()
        publishAirPodsProbeNowPlaying()
    }

    private func ensureSilentAirPodsProbeAudio() {
        guard airPodsControlEnabled else { return }
        guard let engine = airPodsProbeEngine,
              let player = airPodsProbePlayer else {
            startSilentAirPodsProbeAudio()
            return
        }

        if !engine.isRunning {
            try? engine.start()
        }

        if !player.isPlaying {
            player.play()
        }
    }

    private func startSilentAirPodsProbeAudio() {
        guard airPodsProbeEngine == nil, airPodsProbePlayer == nil else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        player.volume = 0
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            airPodsProbeEngine = engine
            airPodsProbePlayer = player
        } catch {
            engine.detach(player)
        }
    }

    private func stopSilentAirPodsProbeAudio() {
        airPodsProbePlayer?.stop()
        airPodsProbeEngine?.stop()
        if let airPodsProbeEngine, let airPodsProbePlayer {
            airPodsProbeEngine.detach(airPodsProbePlayer)
        }
        airPodsProbePlayer = nil
        airPodsProbeEngine = nil
    }

    private func publishAirPodsProbeNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "wire AirPods Control",
            MPMediaItemPropertyArtist: "wire",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
        ]
        center.playbackState = .playing
    }

    private func clearAirPodsProbeNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        guard usagePage == kHIDPage_Consumer else { return }
        if usage == Self.playPauseUsage {
            handlePlayPauseValue(intValue)
        } else if usage == Self.nextTrackUsage, intValue != 0 {
            Self.appendAirPodsDebugLog("hid usage=nextTrack recording=\(isRecording())")
            handleAirPodsRemoteCommand("hid nextTrack")
        }
    }

    private func handlePlayPauseValue(_ value: CFIndex) {
        if value != 0 {
            headsetPressStartedAt = Date()
            longPressActive = false
            longPressWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.activateLongPressIfStillDown()
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressThreshold, execute: workItem)
        } else {
            let shouldStopHold = longPressActive && mode == .longPressHold
            cancelPendingLongPress()
            if shouldStopHold {
                DispatchQueue.main.async { [onHoldReleased] in
                    onHoldReleased()
                }
            }
        }
    }

    private func activateLongPressIfStillDown() {
        guard headsetPressStartedAt != nil, mode.controlsWiredRecording, !longPressActive else { return }
        longPressActive = true

        switch mode {
        case .longPressHold:
            onHoldPressed()
        case .longPressToggle:
            onTogglePressed()
        }
    }

    private func cancelPendingLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        headsetPressStartedAt = nil
        longPressActive = false
    }
}

// MARK: - Audio Recorder

final class AudioRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var tempURL: URL?
    private var audioQueue: AudioQueueRef?
    private var audioQueueFile: AudioFileID?
    private var audioQueueTempURL: URL?
    private var audioQueueFormat = AudioStreamBasicDescription()
    private var audioQueuePacketIndex: Int64 = 0
    private var audioQueueIsRunning = false

    private static func appendRecorderDebugLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/wire-recorder.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    var isRecording: Bool { engine?.isRunning ?? false }
    var hasActiveRecording: Bool {
        (engine != nil && tempURL != nil) || audioQueue != nil
    }

    /// Start recording to a temporary WAV file
    func start(inputDeviceID: AudioDeviceID? = nil) throws {
        guard !hasActiveRecording else { return }
        if inputDeviceID != nil {
            try startBuiltInMicCapture()
            return
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        self.tempURL = tempURL

        // Write using the actual microphone format so AVAudioFile.write(from:) succeeds.
        let file = try AVAudioFile(forWriting: tempURL,
                                   settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        self.outputFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func startBuiltInMicCapture() throws {
        let deviceUID = try DefaultAudioInputOverride.builtInInputDeviceUID()
        let deviceName = try DefaultAudioInputOverride.builtInInputDeviceName()
        Self.appendRecorderDebugLog("start-built-in deviceName=\(deviceName) uid=\(deviceUID)")
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var queue: AudioQueueRef?
        var status = AudioQueueNewInput(
            &format,
            Self.audioQueueInputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )
        guard status == noErr, let queue else {
            throw AppError.transcriptionFailed("Could not start Mac microphone recorder: \(status)")
        }

        var currentDevice = deviceUID as CFString
        status = withUnsafePointer(to: &currentDevice) { pointer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        guard status == noErr else {
            AudioQueueDispose(queue, true)
            throw AppError.transcriptionFailed("Could not select Mac microphone: \(status)")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        var file: AudioFileID?
        status = AudioFileCreateWithURL(tempURL as CFURL, kAudioFileCAFType, &format, .eraseFile, &file)
        guard status == noErr, let file else {
            AudioQueueDispose(queue, true)
            throw AppError.transcriptionFailed("Could not create microphone recording file: \(status)")
        }

        audioQueue = queue
        audioQueueFile = file
        audioQueueTempURL = tempURL
        audioQueueFormat = format
        audioQueuePacketIndex = 0
        audioQueueIsRunning = true

        let bufferByteSize: UInt32 = 32_768
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer)
            guard status == noErr, let buffer else {
                _ = stopBuiltInMicCapture()
                throw AppError.transcriptionFailed("Could not allocate microphone buffer: \(status)")
            }
            status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            guard status == noErr else {
                _ = stopBuiltInMicCapture()
                throw AppError.transcriptionFailed("Could not queue microphone buffer: \(status)")
            }
        }

        status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            _ = stopBuiltInMicCapture()
            throw AppError.transcriptionFailed("Could not start microphone capture: \(status)")
        }
    }

    private static let audioQueueInputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, packetCount, packetDescriptions in
        guard let userData else { return }
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue()
        recorder.handleAudioQueueBuffer(queue: queue, buffer: buffer, packetCount: packetCount, packetDescriptions: packetDescriptions)
    }

    private func handleAudioQueueBuffer(
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        packetCount: UInt32,
        packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
    ) {
        guard audioQueueIsRunning, let file = audioQueueFile else { return }

        var packetsToWrite = packetCount
        if packetsToWrite == 0, audioQueueFormat.mBytesPerPacket > 0 {
            packetsToWrite = buffer.pointee.mAudioDataByteSize / audioQueueFormat.mBytesPerPacket
        }

        if packetsToWrite > 0 {
            var mutablePacketCount = packetsToWrite
            let status = AudioFileWritePackets(
                file,
                false,
                buffer.pointee.mAudioDataByteSize,
                packetDescriptions,
                audioQueuePacketIndex,
                &mutablePacketCount,
                buffer.pointee.mAudioData
            )
            if status == noErr {
                audioQueuePacketIndex += Int64(mutablePacketCount)
            }
        }

        if audioQueueIsRunning {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    /// Stop recording and return the audio data
    private func stopAndTranscribe() -> Data? {
        if audioQueue != nil || audioQueueFile != nil {
            return stopBuiltInMicCapture()
        }
        guard let engine = engine, let url = tempURL else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        outputFile = nil
        self.tempURL = nil

        defer { try? FileManager.default.removeItem(at: url) }
        return normalizedWavData(from: url) ?? (try? Data(contentsOf: url))
    }

    private func stopBuiltInMicCapture() -> Data? {
        audioQueueIsRunning = false
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
        }
        if let audioQueueFile {
            AudioFileClose(audioQueueFile)
        }
        let url = audioQueueTempURL
        resetBuiltInMicCapture()
        guard let url else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return normalizedWavData(from: url) ?? (try? Data(contentsOf: url))
    }

    private func resetBuiltInMicCapture() {
        audioQueue = nil
        audioQueueFile = nil
        audioQueueTempURL = nil
        audioQueuePacketIndex = 0
    }

    private func normalizedWavData(from inputURL: URL) -> Data? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", inputURL.path, outputURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = try Data(contentsOf: outputURL)
            try? data.write(to: URL(fileURLWithPath: "/tmp/wire-last-recording.wav"))
            return data
        } catch {
            return nil
        }
    }

    /// Stop recording and return the captured audio data
    func stop() -> Data? {
        return stopAndTranscribe()
    }
}

// MARK: - Codex API Client (WKWebView-backed)

final class CodexAPIClient: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false

    private var authToken: String = ""
    private var accountID: String = ""
    private var transcriptionContinuation: CheckedContinuation<String, Error>?

    /// Read token from ~/.codex/auth.json and prepare the WKWebView session
    func prepare() async throws {
        try readAuthToken()
        try await setupWebView()
    }

    private func readAuthToken() throws {
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw AppError.authFileNotFound
        }

        let data = try Data(contentsOf: authPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tokens = json?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String else {
            throw AppError.tokenNotFound
        }

        self.authToken = token
        self.accountID = account
    }

    private func setupWebView() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation

            let config = WKWebViewConfiguration()
            let userContentController = WKUserContentController()
            userContentController.add(self, name: "transcribeResult")
            config.userContentController = userContentController
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Codex Desktop/26.513.20950 (Macintosh; Intel Mac OS X)"
            self.webView = webView

            // Load chatgpt.com to establish Cloudflare session
            let request = URLRequest(url: URL(string: "https://chatgpt.com")!)
            webView.load(request)

            // Timeout: if navigation takes >15s, proceed anyway
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.isReady else { return }
                self.isReady = true
                self.readyContinuation?.resume()
                self.readyContinuation = nil
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        if url.contains("chatgpt.com") {
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Might still work if it partially loaded (Cloudflare handled)
        if !isReady {
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !isReady {
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    private func makeMultipartBody(audioData: Data, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "transcribeResult" else { return }
        guard let continuation = transcriptionContinuation else { return }
        transcriptionContinuation = nil

        let jsonString: String
        if let string = message.body as? String {
            jsonString = string
        } else if JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body),
                  let string = String(data: data, encoding: .utf8) {
            jsonString = string
        } else {
            continuation.resume(throwing: AppError.transcriptionFailed("Invalid JavaScript callback"))
            return
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            continuation.resume(throwing: AppError.transcriptionFailed("Invalid response"))
            return
        }

        if let success = json["success"] as? Bool, success,
           let text = json["text"] as? String {
            continuation.resume(returning: text)
        } else {
            let errorMsg = json["error"] as? String ?? "Unknown error"
            continuation.resume(throwing: AppError.transcriptionFailed(errorMsg))
        }
    }

    // MARK: - Transcribe

    func transcribe(audioData: Data) async throws -> String {
        guard isReady, let webView = webView else {
            throw AppError.sessionNotReady
        }

        let base64Audio = audioData.base64EncodedString()
        let token = authToken
        let account = accountID

        let functionBody = """
        const binaryStr = atob(audioBase64);
        const bytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) {
            bytes[i] = binaryStr.charCodeAt(i);
        }
        const blob = new Blob([bytes], { type: 'audio/wav' });
        const formData = new FormData();
        formData.append('file', blob, 'recording.wav');

        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 80000);
        try {
            const response = await fetch('https://chatgpt.com/backend-api/transcribe', {
                method: 'POST',
                headers: {
                    'Authorization': 'Bearer ' + authToken,
                    'ChatGPT-Account-Id': accountID,
                    'originator': 'codex_desktop'
                },
                body: formData,
                signal: controller.signal
            });
            clearTimeout(timeout);

            const responseText = await response.text();
            if (!response.ok) {
                return JSON.stringify({ success: false, error: 'HTTP ' + response.status + ': ' + responseText.substring(0, 800) });
            }

            let result;
            try {
                result = JSON.parse(responseText);
            } catch (e) {
                return JSON.stringify({ success: false, error: 'Invalid JSON: ' + responseText.substring(0, 800) });
            }
            return JSON.stringify({ success: true, text: result.text || '' });
        } catch (e) {
            clearTimeout(timeout);
            return JSON.stringify({ success: false, error: e && e.name === 'AbortError' ? 'ChatGPT request timed out in WebView' : (e.message || String(e)) });
        }
        """

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            func finish(_ result: Result<String, Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 110) {
                finish(.failure(AppError.transcriptionFailed("Timed out waiting for ChatGPT transcription response")))
            }

            webView.callAsyncJavaScript(
                functionBody,
                arguments: [
                    "audioBase64": base64Audio,
                    "authToken": token,
                    "accountID": account
                ],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let jsonString = value as? String,
                          let jsonData = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        finish(.failure(AppError.transcriptionFailed("Invalid JavaScript result")))
                        return
                    }

                    if let success = json["success"] as? Bool, success,
                       let text = json["text"] as? String {
                        finish(.success(text))
                    } else {
                        let errorMsg = json["error"] as? String ?? "Unknown error"
                        finish(.failure(AppError.transcriptionFailed(errorMsg)))
                    }
                case .failure(let error):
                    finish(.failure(AppError.transcriptionFailed(error.localizedDescription)))
                }
            }
        }
    }

    func cleanup() {
        webView?.stopLoading()
        webView = nil
        isReady = false
    }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case authFileNotFound
    case tokenNotFound
    case sessionNotReady
    case transcriptionFailed(String)
    case hotKeyUnsupported
    case hotKeyConflict
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .authFileNotFound:
            return "Codex auth file not found (~/.codex/auth.json). Log into Codex first."
        case .tokenNotFound:
            return "Could not read access token from Codex auth file."
        case .sessionNotReady:
            return "Session not ready. Make sure you're logged into ChatGPT."
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        case .hotKeyUnsupported:
            return "Use a shortcut with ⌘, ⌃, ⌥, or ⇧."
        case .hotKeyConflict:
            return "Toggle and hold shortcuts must be different."
        case .recordingFailed:
            return "Failed to capture audio."
        }
    }
}

// MARK: - Popover View Controller

final class HoverMenuButton: NSButton {
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        updateBackground()
    }

    private func updateBackground() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
    }
}

final class PopoverViewController: NSViewController, NSTextFieldDelegate {
    private enum Layout {
        static let width: CGFloat = 300
    }

    private let state: AppState
    private let hotKeyManager: HotKeyManager
    private let headsetProbeManager: HeadsetProbeManager
    private let rootStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let toggleShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let holdShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let headsetModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headsetControlsSwitch = NSSwitch()
    private let sendEnterAfterPasteSwitch = NSSwitch()
    private let airPodsControlSwitch = NSSwitch()
    private let airPodsInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerControlsSwitch = NSSwitch()
    private let computerInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerCustomHarnessSwitch = NSSwitch()
    private let computerHarnessInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerAutoEnableSwitch = NSSwitch()
    private let computerAutoEnableField = NSTextField(string: "")
    private let computerHarnessField = NSTextField(string: "")
    private let transcriptLabel = NSTextField(labelWithString: "No recent transcription")
    private let copyLatestButton = NSButton(title: "", target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()
    private var headsetSettingsRows: [NSView] = []
    private var computerModeRows: [NSView] = []
    private var computerAutoEnableRows: [NSView] = []
    private var computerHarnessRows: [NSView] = []
    private var headsetCollapsedSpacer: NSView?
    private var airPodsInfoPopover: NSPopover?
    private var computerInfoPopover: NSPopover?
    private var computerHarnessInfoPopover: NSPopover?
    private var shortcutMonitor: Any?
    private var shortcutCaptureTarget: HotKeyKind?
    private var shortcutCaptureKeyCode: UInt32?
    private var shortcutCaptureModifiers: UInt32 = 0
    private var shortcutCaptureCurrentModifiers: UInt32 = 0
    private var shortcutCapturePressedKeyCodes = Set<UInt16>()
    private var computerAutoEnableSaveWorkItem: DispatchWorkItem?
    private var computerHarnessSaveWorkItem: DispatchWorkItem?

    init(state: AppState, hotKeyManager: HotKeyManager, headsetProbeManager: HeadsetProbeManager) {
        self.state = state
        self.hotKeyManager = hotKeyManager
        self.headsetProbeManager = headsetProbeManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 0))
        visual.material = .menu
        visual.blendingMode = .behindWindow
        visual.state = .active
        view = visual
        buildUI()
        refresh()
    }

    private func buildUI() {
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.detachesHiddenViews = true
        rootStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 11, right: 14)

        let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) ?? NSImage())
        mic.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        mic.contentTintColor = .controlAccentColor
        mic.widthAnchor.constraint(equalToConstant: 14).isActive = true
        mic.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 5
        let title = NSTextField(labelWithString: "wire")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        titleRow.addArrangedSubview(mic)
        titleRow.addArrangedSubview(title)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        titleStack.addArrangedSubview(titleRow)
        titleStack.addArrangedSubview(statusLabel)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        loadingIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(loadingIndicator)
        rootStack.addArrangedSubview(header)
        rootStack.addArrangedSubview(divider())

        rootStack.addArrangedSubview(sectionLabel("Latest"))
        transcriptLabel.font = .systemFont(ofSize: 12)
        transcriptLabel.textColor = .secondaryLabelColor
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.maximumNumberOfLines = 3
        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyLatestButton.target = self
        copyLatestButton.action = #selector(copyLatest)
        copyLatestButton.bezelStyle = .inline
        copyLatestButton.isBordered = false
        copyLatestButton.imagePosition = .imageOnly
        copyLatestButton.toolTip = "Copy latest transcription"
        if let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy latest") {
            copyImage.isTemplate = true
            copyLatestButton.image = copyImage
        }
        copyLatestButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        copyLatestButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let latestRow = NSStackView()
        latestRow.orientation = .horizontal
        latestRow.alignment = .centerY
        latestRow.spacing = 8
        latestRow.addArrangedSubview(transcriptLabel)
        latestRow.addArrangedSubview(copyLatestButton)
        rootStack.addArrangedSubview(padded(latestRow, left: 14, right: 14, top: 3, bottom: 8))

        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(sectionLabel("Settings"))
        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(captureHoldShortcut)
        rootStack.addArrangedSubview(menuRow(symbol: "keyboard.badge.ellipsis", title: "Hold shortcut", trailing: holdShortcutButton))
        rootStack.addArrangedSubview(spacer(height: 7))

        toggleShortcutButton.target = self
        toggleShortcutButton.action = #selector(captureToggleShortcut)
        rootStack.addArrangedSubview(menuRow(symbol: "keyboard", title: "Toggle shortcut", trailing: toggleShortcutButton))
        rootStack.addArrangedSubview(spacer(height: 8))

        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(sectionLabel("Headset"))
        configureSwitch(headsetControlsSwitch, action: #selector(toggleHeadsetControls))
        rootStack.addArrangedSubview(menuRow(symbol: "switch.2", title: "Headset controls", trailing: headsetControlsSwitch))
        let collapsedSpacer = spacer(height: 7)
        rootStack.addArrangedSubview(collapsedSpacer)
        headsetCollapsedSpacer = collapsedSpacer

        headsetModePopup.addItems(withTitles: HeadsetButtonMode.allCases.map(\.title))
        headsetModePopup.target = self
        headsetModePopup.action = #selector(changeHeadsetMode)
        headsetModePopup.widthAnchor.constraint(equalToConstant: 178).isActive = true
        let wiredButtonRow = menuRow(symbol: "headphones", title: "Wired", trailing: headsetModePopup)
        rootStack.addArrangedSubview(wiredButtonRow)

        configureSwitch(airPodsControlSwitch, action: #selector(toggleAirPodsControl))
        airPodsInfoButton.bezelStyle = .inline
        airPodsInfoButton.isBordered = false
        airPodsInfoButton.imagePosition = .imageOnly
        airPodsInfoButton.target = self
        airPodsInfoButton.action = #selector(showAirPodsInfo)
        if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Experimental AirPods details") {
            infoImage.isTemplate = true
            airPodsInfoButton.image = infoImage
        }
        airPodsInfoButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        airPodsInfoButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let airPodsControlRow = menuRow(symbol: "airpodspro", title: "AirPods controls (experimental)", trailing: trailingGroup([airPodsInfoButton, airPodsControlSwitch]))
        rootStack.addArrangedSubview(airPodsControlRow)

        configureSwitch(sendEnterAfterPasteSwitch, action: #selector(toggleSendEnterAfterPaste))
        let sendEnterRow = menuRow(symbol: "return", title: "Press Return after paste", trailing: sendEnterAfterPasteSwitch)
        rootStack.addArrangedSubview(sendEnterRow)
        let headsetBottomSpacer = spacer(height: 5)
        rootStack.addArrangedSubview(headsetBottomSpacer)
        headsetSettingsRows = [wiredButtonRow, airPodsControlRow, sendEnterRow, headsetBottomSpacer]

        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(sectionLabel("Computer"))
        configureSwitch(computerControlsSwitch, action: #selector(toggleComputerControls))
        computerInfoButton.bezelStyle = .inline
        computerInfoButton.isBordered = false
        computerInfoButton.imagePosition = .imageOnly
        computerInfoButton.target = self
        computerInfoButton.action = #selector(showComputerInfo)
        if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Computer mode details") {
            infoImage.isTemplate = true
            computerInfoButton.image = infoImage
        }
        computerInfoButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        computerInfoButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        rootStack.addArrangedSubview(menuRow(symbol: "desktopcomputer", title: "Computer mode (dangerous)", trailing: trailingGroup([computerInfoButton, computerControlsSwitch])))

        configureSwitch(computerCustomHarnessSwitch, action: #selector(toggleComputerCustomHarness))
        computerHarnessInfoButton.bezelStyle = .inline
        computerHarnessInfoButton.isBordered = false
        computerHarnessInfoButton.imagePosition = .imageOnly
        computerHarnessInfoButton.target = self
        computerHarnessInfoButton.action = #selector(showComputerHarnessInfo)
        if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Custom harness details") {
            infoImage.isTemplate = true
            computerHarnessInfoButton.image = infoImage
        }
        computerHarnessInfoButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        computerHarnessInfoButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let customHarnessToggleRow = menuRow(symbol: "terminal", title: "Custom harness", trailing: trailingGroup([computerHarnessInfoButton, computerCustomHarnessSwitch]))
        rootStack.addArrangedSubview(customHarnessToggleRow)

        computerHarnessField.placeholderString = "codex --yolo -c 'model_reasoning_effort=\"low\"' e {{prompt}}"
        computerHarnessField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        computerHarnessField.bezelStyle = .roundedBezel
        computerHarnessField.focusRingType = .none
        computerHarnessField.controlSize = .small
        computerHarnessField.delegate = self
        computerHarnessField.target = self
        computerHarnessField.action = #selector(updateComputerHarnessCommand)
        computerHarnessField.widthAnchor.constraint(equalToConstant: 176).isActive = true
        computerHarnessField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let commandRow = menuRow(symbol: "chevron.right.square", title: "Command", trailing: computerHarnessField)
        rootStack.addArrangedSubview(commandRow)

        configureSwitch(computerAutoEnableSwitch, action: #selector(toggleComputerAutoEnable))
        let autoEnableToggleRow = menuRow(symbol: "bolt.badge.automatic", title: "Auto enable", trailing: computerAutoEnableSwitch)
        rootStack.addArrangedSubview(autoEnableToggleRow)

        computerAutoEnableField.placeholderString = "At least two words"
        computerAutoEnableField.font = .systemFont(ofSize: 12)
        computerAutoEnableField.bezelStyle = .roundedBezel
        computerAutoEnableField.focusRingType = .none
        computerAutoEnableField.controlSize = .small
        computerAutoEnableField.delegate = self
        computerAutoEnableField.target = self
        computerAutoEnableField.action = #selector(updateComputerAutoEnablePhrase)
        computerAutoEnableField.widthAnchor.constraint(equalToConstant: 142).isActive = true
        computerAutoEnableField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let phraseRow = menuRow(symbol: "text.cursor", title: "Phrase", trailing: computerAutoEnableField)
        rootStack.addArrangedSubview(phraseRow)
        let computerBottomSpacer = spacer(height: 9)
        rootStack.addArrangedSubview(computerBottomSpacer)
        computerModeRows = [customHarnessToggleRow]
        computerHarnessRows = [commandRow]
        computerAutoEnableRows = [phraseRow]

        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(clickableMenuRow(symbol: "power", title: "Quit", action: #selector(quitApp), destructive: true))
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return padded(label, left: 14, right: 14, top: 8, bottom: 7)
    }

    private func padded(_ child: NSView, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) -> NSView {
        let container = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: left),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -right),
            child.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom)
        ])
        return container
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.target = self
        control.action = action
        control.controlSize = .small
        control.widthAnchor.constraint(equalToConstant: 38).isActive = true
        control.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func menuRow(symbol: String, title: String, trailing: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.addArrangedSubview(trailing)
        return row
    }

    private func trailingGroup(_ views: [NSView]) -> NSView {
        let group = NSStackView()
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        for view in views {
            group.addArrangedSubview(view)
        }
        return group
    }

    private func clickableMenuRow(symbol: String, title: String, action: Selector, destructive: Bool = false) -> NSView {
        let button = HoverMenuButton(title: "", target: self, action: action)
        return clickableMenuRow(symbol: symbol, title: title, button: button, destructive: destructive)
    }

    private func clickableMenuRow(symbol: String, title: String, button: NSButton, destructive: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .center
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        container.addSubview(button)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = destructive ? .systemRed : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        if destructive {
            label.textColor = .systemRed
        }

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        button.addSubview(row)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 38),
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 108),
            button.heightAnchor.constraint(equalToConstant: 30),
            row.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return container
    }

    func refresh() {
        guard isViewLoaded else { return }
        let apply = { [weak self] in
            guard let self else { return }
            let autoEnablePhrase = self.computerAutoEnableField.currentEditor() == nil
                ? self.state.computerAutoEnablePhrase
                : self.computerAutoEnableField.stringValue
            let hasInvalidAutoEnablePhrase = self.state.computerAutoEnableEnabled && self.autoEnablePhraseWordCount(autoEnablePhrase) < 2
            self.statusLabel.stringValue = hasInvalidAutoEnablePhrase
                ? "Minimum 2 words"
                : (self.state.statusText.isEmpty ? "Ready" : self.state.statusText)
            self.statusLabel.textColor = hasInvalidAutoEnablePhrase ? .systemRed : .secondaryLabelColor
            if self.shortcutCaptureTarget == nil {
                self.holdShortcutButton.title = self.hotKeyManager.holdShortcutDisplay
                self.toggleShortcutButton.title = self.hotKeyManager.toggleShortcutDisplay
            } else {
                if self.shortcutCaptureTarget != .hold {
                    self.holdShortcutButton.title = self.hotKeyManager.holdShortcutDisplay
                }
                if self.shortcutCaptureTarget != .toggle {
                    self.toggleShortcutButton.title = self.hotKeyManager.toggleShortcutDisplay
                }
                self.updateShortcutCaptureDisplay()
            }

            switch self.state.transcriptionStage {
            case .recording:
                self.loadingIndicator.stopAnimation(nil)
            case .transcribing:
                self.loadingIndicator.startAnimation(nil)
            default:
                if self.state.computerCommandRunning {
                    self.loadingIndicator.startAnimation(nil)
                } else {
                    self.loadingIndicator.stopAnimation(nil)
                }
            }

            self.headsetControlsSwitch.state = self.state.headsetControlsEnabled ? .on : .off
            self.headsetModePopup.selectItem(at: self.headsetProbeManager.currentMode.rawValue)
            self.airPodsControlSwitch.state = self.headsetProbeManager.isAirPodsControlEnabled ? .on : .off
            self.sendEnterAfterPasteSwitch.state = self.state.sendEnterAfterPaste ? .on : .off
            self.computerControlsSwitch.state = self.state.computerControlsEnabled ? .on : .off
            self.computerCustomHarnessSwitch.state = self.state.computerCustomHarnessEnabled ? .on : .off
            self.computerAutoEnableSwitch.state = self.state.computerAutoEnableEnabled ? .on : .off
            if self.computerAutoEnableField.currentEditor() == nil {
                self.computerAutoEnableField.stringValue = self.state.computerAutoEnablePhrase
            }
            if self.computerHarnessField.currentEditor() == nil {
                self.computerHarnessField.stringValue = self.state.computerHarnessCommand
            }
            self.headsetModePopup.isEnabled = self.state.headsetControlsEnabled
            self.airPodsControlSwitch.isEnabled = self.state.headsetControlsEnabled
            self.airPodsInfoButton.isEnabled = self.state.headsetControlsEnabled
            self.sendEnterAfterPasteSwitch.isEnabled = self.state.headsetControlsEnabled
            self.headsetSettingsRows.forEach { $0.isHidden = !self.state.headsetControlsEnabled }
            self.headsetCollapsedSpacer?.isHidden = self.state.headsetControlsEnabled
            self.computerModeRows.forEach { $0.isHidden = !self.state.computerControlsEnabled }
            let showComputerCommand = self.state.computerControlsEnabled && self.state.computerCustomHarnessEnabled
            self.computerHarnessRows.forEach { $0.isHidden = !showComputerCommand }
            let showComputerPhrase = self.state.computerAutoEnableEnabled
            self.computerAutoEnableRows.forEach { $0.isHidden = !showComputerPhrase }

            if self.state.computerCommandRunning {
                let usesCustomHarness = self.state.computerCustomHarnessEnabled && !self.state.computerHarnessCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self.transcriptLabel.stringValue = usesCustomHarness ? "Running harness..." : "Running codex..."
            } else if self.state.transcriptionStage == .transcribing {
                self.transcriptLabel.stringValue = "Loading… transcribing audio"
            } else {
                self.transcriptLabel.stringValue = self.state.lastTranscription.isEmpty ? "No recent transcription" : self.state.lastTranscription
            }
            self.copyLatestButton.isEnabled = !self.transcriptLabel.stringValue.isEmpty && self.transcriptLabel.stringValue != "No recent transcription"
            self.updatePreferredContentSize()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func updatePreferredContentSize() {
        let latestTextWidth = Layout.width - 14 - 14 - 8 - 24
        transcriptLabel.preferredMaxLayoutWidth = latestTextWidth
        view.layoutSubtreeIfNeeded()
        rootStack.layoutSubtreeIfNeeded()

        let height = ceil(rootStack.fittingSize.height)
        preferredContentSize = NSSize(width: Layout.width, height: height)
    }

    private func autoEnablePhraseWordCount(_ phrase: String) -> Int {
        phrase
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .count
    }

    @objc private func trigger() {
        (NSApp.delegate as? AppDelegate)?.perform(#selector(AppDelegate.handleTranscribeObjc), with: nil, afterDelay: 0)
    }

    @objc private func copyLatest() {
        guard !state.lastTranscription.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.lastTranscription, forType: .string)
        state.statusText = "Copied latest transcription"
    }

    @objc private func toggleHeadsetControls() {
        (NSApp.delegate as? AppDelegate)?.setHeadsetControlsEnabled(headsetControlsSwitch.state == .on)
        refresh()
    }

    @objc private func changeHeadsetMode() {
        let selectedMode = HeadsetButtonMode(rawValue: headsetModePopup.indexOfSelectedItem) ?? .longPressHold
        headsetProbeManager.setMode(selectedMode)
        refresh()
    }

    @objc private func toggleAirPodsControl() {
        headsetProbeManager.setAirPodsControlEnabled(airPodsControlSwitch.state == .on)
        refresh()
    }

    @objc private func showAirPodsInfo() {
        if let airPodsInfoPopover, airPodsInfoPopover.isShown {
            airPodsInfoPopover.performClose(nil)
            return
        }

        let label = NSTextField(labelWithString: "Left tap (next track) starts/stops recording.\nUses this Mac's microphone.\nMay interrupt music controls.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 198
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 222, height: 88))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 222),
            container.heightAnchor.constraint(equalToConstant: 88),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 222, height: 88)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 222, height: 88)
        popover.contentViewController = controller
        airPodsInfoPopover = popover
        popover.show(relativeTo: airPodsInfoButton.bounds, of: airPodsInfoButton, preferredEdge: .maxY)
    }

    @objc private func toggleSendEnterAfterPaste() {
        (NSApp.delegate as? AppDelegate)?.setSendEnterAfterPaste(sendEnterAfterPasteSwitch.state == .on)
        refresh()
    }

    @objc private func toggleComputerControls() {
        (NSApp.delegate as? AppDelegate)?.setComputerControlsEnabled(computerControlsSwitch.state == .on)
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    @objc private func toggleComputerCustomHarness() {
        (NSApp.delegate as? AppDelegate)?.setComputerCustomHarnessEnabled(computerCustomHarnessSwitch.state == .on)
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    @objc private func toggleComputerAutoEnable() {
        (NSApp.delegate as? AppDelegate)?.setComputerAutoEnableEnabled(computerAutoEnableSwitch.state == .on)
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    @objc private func updateComputerAutoEnablePhrase() {
        computerAutoEnableSaveWorkItem?.cancel()
        (NSApp.delegate as? AppDelegate)?.setComputerAutoEnablePhrase(computerAutoEnableField.stringValue)
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    @objc private func updateComputerHarnessCommand() {
        computerHarnessSaveWorkItem?.cancel()
        (NSApp.delegate as? AppDelegate)?.setComputerHarnessCommand(computerHarnessField.stringValue)
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === computerAutoEnableField {
            updateComputerAutoEnablePhrase()
        } else if obj.object as? NSTextField === computerHarnessField {
            updateComputerHarnessCommand()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === computerAutoEnableField {
            scheduleComputerAutoEnablePhraseSave()
            refresh()
        } else if obj.object as? NSTextField === computerHarnessField {
            scheduleComputerHarnessCommandSave()
            refresh()
        }
    }

    private func scheduleComputerAutoEnablePhraseSave() {
        computerAutoEnableSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.setComputerAutoEnablePhrase(self.computerAutoEnableField.stringValue)
        }
        computerAutoEnableSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func scheduleComputerHarnessCommandSave() {
        computerHarnessSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.setComputerHarnessCommand(self.computerHarnessField.stringValue)
        }
        computerHarnessSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    @objc private func showComputerInfo() {
        if let computerInfoPopover, computerInfoPopover.isShown {
            computerInfoPopover.performClose(nil)
            return
        }

        let label = NSTextField(labelWithString: "When Computer mode is on, each transcript runs through a local shell command with full execution permissions.\nBy default it runs Codex with low reasoning effort.\nAuto enable only works when its switch is on and the phrase has at least two words.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 218
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 254, height: 148))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 254),
            container.heightAnchor.constraint(equalToConstant: 148),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 254, height: 148)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 254, height: 148)
        popover.contentViewController = controller
        computerInfoPopover = popover
        popover.show(relativeTo: computerInfoButton.bounds, of: computerInfoButton, preferredEdge: .maxY)
    }

    @objc private func showComputerHarnessInfo() {
        if let computerHarnessInfoPopover, computerHarnessInfoPopover.isShown {
            computerHarnessInfoPopover.performClose(nil)
            return
        }

        let label = NSTextField(labelWithString: "Custom harness replaces the default Codex command.\nUse {{prompt}} where the transcript should go.\nIf {{prompt}} is missing, the transcript is appended at the end.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 218
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 254, height: 124))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 254),
            container.heightAnchor.constraint(equalToConstant: 124),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 254, height: 124)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 254, height: 124)
        popover.contentViewController = controller
        computerHarnessInfoPopover = popover
        popover.show(relativeTo: computerHarnessInfoButton.bounds, of: computerHarnessInfoButton, preferredEdge: .maxY)
    }

    @objc private func captureToggleShortcut() {
        captureShortcut(for: .toggle)
    }

    @objc private func captureHoldShortcut() {
        captureShortcut(for: .hold)
    }

    private func captureShortcut(for target: HotKeyKind) {
        guard shortcutMonitor == nil else { return }
        shortcutCaptureTarget = target
        shortcutCaptureKeyCode = nil
        shortcutCaptureModifiers = 0
        shortcutCaptureCurrentModifiers = 0
        shortcutCapturePressedKeyCodes.removeAll()
        hotKeyManager.suspendShortcuts()
        state.statusText = "Press new \(target.label.lowercased()) shortcut…"
        updateShortcutCaptureDisplay()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleShortcutCapture(event: event)
        }
    }

    private func handleShortcutCapture(event: NSEvent) -> NSEvent? {
        guard shortcutCaptureTarget != nil else { return event }

        shortcutCaptureCurrentModifiers = hotKeyManager.modifiers(from: event.modifierFlags)

        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            finishShortcutCapture(save: false)
            return nil
        }

        switch event.type {
        case .flagsChanged:
            if shortcutCaptureKeyCode == nil {
                shortcutCaptureModifiers = shortcutCaptureCurrentModifiers
            }
            updateShortcutCaptureDisplay()
            finishShortcutCaptureIfReleased()
        case .keyDown:
            guard !event.isARepeat else { return nil }
            shortcutCapturePressedKeyCodes.insert(event.keyCode)
            shortcutCaptureKeyCode = UInt32(event.keyCode)
            if shortcutCaptureCurrentModifiers != 0 {
                shortcutCaptureModifiers = shortcutCaptureCurrentModifiers
            }
            updateShortcutCaptureDisplay()
        case .keyUp:
            shortcutCapturePressedKeyCodes.remove(event.keyCode)
            finishShortcutCaptureIfReleased()
        default:
            break
        }

        return nil
    }

    private func finishShortcutCaptureIfReleased() {
        guard shortcutCaptureKeyCode != nil,
              shortcutCapturePressedKeyCodes.isEmpty,
              shortcutCaptureCurrentModifiers == 0 else { return }
        finishShortcutCapture(save: true)
    }

    private func finishShortcutCapture(save: Bool) {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        guard let target = shortcutCaptureTarget else { return }
        let keyCode = shortcutCaptureKeyCode
        let modifiers = shortcutCaptureModifiers
        shortcutCaptureTarget = nil
        shortcutCaptureKeyCode = nil
        shortcutCaptureModifiers = 0
        shortcutCaptureCurrentModifiers = 0
        shortcutCapturePressedKeyCodes.removeAll()

        guard save, let keyCode else {
            hotKeyManager.registerSavedShortcuts()
            state.statusText = "Shortcut unchanged"
            refresh()
            return
        }

        do {
            try hotKeyManager.updateShortcut(for: target, keyCode: keyCode, modifiers: modifiers)
            state.statusText = "\(target.label) shortcut saved"
        } catch {
            hotKeyManager.registerSavedShortcuts()
            state.statusText = "Shortcut failed: \(error.localizedDescription)"
        }
        refresh()
    }

    private func updateShortcutCaptureDisplay() {
        guard let target = shortcutCaptureTarget else { return }
        let keyCode = shortcutCaptureKeyCode
        let modifiers = keyCode == nil ? shortcutCaptureCurrentModifiers : shortcutCaptureModifiers
        captureButton(for: target).title = hotKeyManager.displayShortcut(modifiers: modifiers, keyCode: keyCode)
    }

    private func captureButton(for target: HotKeyKind) -> NSButton {
        switch target {
        case .toggle:
            return toggleShortcutButton
        case .hold:
            return holdShortcutButton
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - HotKey Manager

enum HotKeyKind: UInt32, CaseIterable {
    case toggle = 1
    case hold = 2

    var label: String {
        switch self {
        case .toggle: return "Toggle"
        case .hold: return "Hold"
        }
    }

    var keyCodeDefaultsKey: String {
        switch self {
        case .toggle: return "toggleHotKeyCode"
        case .hold: return "holdHotKeyCode"
        }
    }

    var modifiersDefaultsKey: String {
        switch self {
        case .toggle: return "toggleHotKeyModifiers"
        case .hold: return "holdHotKeyModifiers"
        }
    }

    var fallbackKeyCode: Int {
        switch self {
        case .toggle: return kVK_ANSI_M
        case .hold: return kVK_ANSI_M
        }
    }

    var fallbackModifiers: Int {
        switch self {
        case .toggle: return cmdKey | shiftKey
        case .hold: return controlKey | optionKey
        }
    }
}

final class HotKeyManager {
    private static let signature = OSType(0x57524548) // WREH

    private let state: AppState
    private let onTogglePressed: () -> Void
    private let onHoldPressed: () -> Void
    private let onHoldReleased: () -> Void
    private var toggleHotKeyRef: EventHotKeyRef?
    private var holdHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(
        state: AppState,
        onTogglePressed: @escaping () -> Void,
        onHoldPressed: @escaping () -> Void,
        onHoldReleased: @escaping () -> Void
    ) {
        self.state = state
        self.onTogglePressed = onTogglePressed
        self.onHoldPressed = onHoldPressed
        self.onHoldReleased = onHoldReleased
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    var toggleShortcutDisplay: String { display(shortcut(for: .toggle)) }
    var holdShortcutDisplay: String { display(shortcut(for: .hold)) }

    func registerSavedShortcuts() {
        registerAll(updateStatus: true)
    }

    func suspendShortcuts() {
        unregisterAll()
    }

    func updateShortcut(for kind: HotKeyKind, keyCode: UInt32, modifiers: UInt32) throws {
        guard modifiers != 0 else { throw AppError.hotKeyUnsupported }
        let otherKind: HotKeyKind = kind == .toggle ? .hold : .toggle
        let other = shortcut(for: otherKind)
        guard other.keyCode != keyCode || other.modifiers != modifiers else { throw AppError.hotKeyConflict }

        UserDefaults.standard.set(Int(keyCode), forKey: kind.keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(modifiers), forKey: kind.modifiersDefaultsKey)
        registerAll(updateStatus: false)
    }

    func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        carbonModifiers(from: flags)
    }

    func displayShortcut(modifiers: UInt32, keyCode: UInt32?) -> String {
        display(modifiers: modifiers, keyCode: keyCode)
    }

    private func registerAll(updateStatus: Bool) {
        unregisterAll()
        let toggleStatus = register(kind: .toggle)
        let holdStatus = register(kind: .hold)

        guard updateStatus else { return }
        if toggleStatus == noErr && holdStatus == noErr {
            state.statusText = "Shortcuts: toggle \(toggleShortcutDisplay), hold \(holdShortcutDisplay)"
        } else if toggleStatus != noErr {
            state.statusText = "Toggle shortcut registration failed: \(toggleStatus)"
        } else {
            state.statusText = "Hold shortcut registration failed: \(holdStatus)"
        }
    }

    private func register(kind: HotKeyKind) -> OSStatus {
        let shortcut = shortcut(for: kind)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: kind.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            switch kind {
            case .toggle:
                toggleHotKeyRef = ref
            case .hold:
                holdHotKeyRef = ref
            }
        }
        return status
    }

    private func unregisterAll() {
        if let toggleHotKeyRef {
            UnregisterEventHotKey(toggleHotKeyRef)
            self.toggleHotKeyRef = nil
        }
        if let holdHotKeyRef {
            UnregisterEventHotKey(holdHotKeyRef)
            self.holdHotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard let kind = manager.hotKeyKind(from: event) else { return noErr }

            switch (kind, GetEventKind(event)) {
            case (.toggle, UInt32(kEventHotKeyPressed)):
                manager.onTogglePressed()
            case (.hold, UInt32(kEventHotKeyPressed)):
                manager.onHoldPressed()
            case (.hold, UInt32(kEventHotKeyReleased)):
                manager.onHoldReleased()
            default:
                break
            }
            return noErr
        }, eventTypes.count, &eventTypes, pointer, &eventHandler)
    }

    private func hotKeyKind(from event: EventRef) -> HotKeyKind? {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else { return nil }
        return HotKeyKind(rawValue: hotKeyID.id)
    }

    private func shortcut(for kind: HotKeyKind) -> (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        let legacyKey = kind == .toggle ? defaults.object(forKey: "hotKeyCode") as? Int : nil
        let legacyModifiers = kind == .toggle ? defaults.object(forKey: "hotKeyModifiers") as? Int : nil
        let keyCode = defaults.object(forKey: kind.keyCodeDefaultsKey) as? Int ?? legacyKey ?? kind.fallbackKeyCode
        let modifiers = defaults.object(forKey: kind.modifiersDefaultsKey) as? Int ?? legacyModifiers ?? kind.fallbackModifiers
        return (UInt32(keyCode), UInt32(modifiers))
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private func display(_ shortcut: (keyCode: UInt32, modifiers: UInt32)) -> String {
        display(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode)
    }

    private func display(modifiers: UInt32, keyCode: UInt32?) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if let keyCode {
            parts.append(keyName(for: keyCode))
        }
        return parts.isEmpty ? "Listening…" : parts.joined()
    }

    private func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Escape): "Escape",
            UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - AppDelegate helper

extension AppDelegate {
    @objc func handleTranscribeObjc() {
        handleTranscribe()
    }
}
