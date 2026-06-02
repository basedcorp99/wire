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
        app.setActivationPolicy(.accessory)
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

// MARK: - Debug Logging

enum DebugLog {
    private static let maxBytes: UInt64 = 256 * 1024

    static func append(_ message: String, to path: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let url = URL(fileURLWithPath: path)
        guard let data = line.data(using: .utf8) else { return }

        rotateIfNeeded(url: url, incomingByteCount: UInt64(data.count))

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded(url: URL, incomingByteCount: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value + incomingByteCount > maxBytes else {
            return
        }

        let rotatedURL = URL(fileURLWithPath: url.path + ".1")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}

// MARK: - Clipboard

enum Clipboard {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            return true
        }
        return copyWithPbcopy(text)
    }

    private static func copyWithPbcopy(_ text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")

        let input = Pipe()
        process.standardInput = input

        do {
            try process.run()
            if let data = text.data(using: .utf8) {
                input.fileHandleForWriting.write(data)
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Background Paste Target

private struct BackgroundPasteTarget {
    let pid: pid_t
    let bundleIdentifier: String?
    let element: AXUIElement
    let selectedTextRange: CFRange?
    let cmuxTarget: CmuxPasteTarget?
    let summary: String
}

private struct CmuxPasteTarget {
    let cliPath: String
    let windowRef: String
    let workspaceRef: String
    let surfaceRef: String
}

private enum BackgroundPasteResult {
    case inserted(String)
    case failed(String)
    case failedWithoutFallback(String)
}

private enum BackgroundPaste {
    static func captureIfTrusted() -> BackgroundPasteTarget? {
        guard AXIsProcessTrusted() else { return nil }

        guard let element = focusedElement() else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let app = NSRunningApplication(processIdentifier: pid)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
        let selectedRange = selectedTextRange(from: element)
        let cmuxTarget = app?.bundleIdentifier == "com.cmuxterm.app" ? captureCmuxTarget(app: app) : nil
        let summaryParts = [
            app?.localizedName,
            app?.bundleIdentifier,
            role,
            subrole,
            title
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let summary = summaryParts.joined(separator: " ")

        return BackgroundPasteTarget(
            pid: pid,
            bundleIdentifier: app?.bundleIdentifier,
            element: element,
            selectedTextRange: selectedRange,
            cmuxTarget: cmuxTarget,
            summary: summary.isEmpty ? "pid=\(pid)" : summary
        )
    }

    static func insert(_ text: String, into target: BackgroundPasteTarget) -> BackgroundPasteResult {
        guard AXIsProcessTrusted() else {
            return .failed("accessibility-not-trusted")
        }

        guard NSRunningApplication(processIdentifier: target.pid) != nil else {
            return .failed("target-app-not-running")
        }

        guard elementStillExists(target.element) else {
            return .failed("target-element-missing")
        }

        if target.bundleIdentifier == "com.cmuxterm.app" {
            if let cmuxTarget = target.cmuxTarget {
                if let failureReason = sendToCmux(text, target: cmuxTarget) {
                    log("cmux-send failed reason=\(failureReason)")
                } else {
                    return .inserted("cmux-send")
                }
            }
            return pasteIntoCmuxProcess(text, target: target)
        }

        guard let initialValue = stringAttribute(kAXValueAttribute as CFString, from: target.element) else {
            return .failed("target-has-no-verifiable-text-value")
        }

        if let range = target.selectedTextRange {
            let restoreSelectionStatus = setSelectedTextRange(range, on: target.element)
            let selectedTextStatus = AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if selectedTextStatus == .success,
               valueChanged(from: initialValue, inserting: text, on: target.element) {
                let insertionLocation = range.location + (text as NSString).length
                _ = setSelectedTextRange(CFRange(location: insertionLocation, length: 0), on: target.element)
                return .inserted("selected-text")
            }

            var failureReasons = [
                "selectedText=\(selectedTextStatus.wireDescription)",
                "restoreSelection=\(restoreSelectionStatus.wireDescription)"
            ]

            if let valueResult = insertByReplacingValue(
                text,
                range: range,
                initialValue: initialValue,
                element: target.element
            ) {
                if case .inserted = valueResult {
                    return valueResult
                } else if case .failed(let reason) = valueResult {
                    failureReasons.append(reason)
                }
            }

            return .failed(failureReasons.joined(separator: " "))
        }

        return .failed("target-has-no-selected-text-range")
    }

    private static func insertByReplacingValue(
        _ text: String,
        range: CFRange,
        initialValue: String?,
        element: AXUIElement
    ) -> BackgroundPasteResult? {
        guard isAttributeSettable(kAXValueAttribute as CFString, on: element) else {
            return nil
        }

        guard let currentValue = initialValue ?? stringAttribute(kAXValueAttribute as CFString, from: element) else {
            return .failed("target-value-unavailable")
        }

        guard let updatedValue = currentValue.replacingUTF16Range(range, with: text) else {
            return .failed("target-selection-out-of-range")
        }

        let setValueStatus = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueStatus == .success else {
            return .failed("setValue=\(setValueStatus.wireDescription)")
        }

        guard valueChanged(from: currentValue, inserting: text, on: element) else {
            return .failed("setValue-unverified")
        }

        let insertionLocation = range.location + (text as NSString).length
        _ = setSelectedTextRange(CFRange(location: insertionLocation, length: 0), on: element)
        return .inserted("value")
    }

    private static func pasteIntoCmuxProcess(_ text: String, target: BackgroundPasteTarget) -> BackgroundPasteResult {
        guard Clipboard.copy(text) else {
            return .failedWithoutFallback("cmux-clipboard-copy-failed")
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        guard let commandDown, let vDown, let vUp, let commandUp else {
            return .failedWithoutFallback("cmux-key-event-create-failed")
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.postToPid(target.pid)
        vDown.postToPid(target.pid)
        vUp.postToPid(target.pid)
        commandUp.postToPid(target.pid)
        return .inserted("cmux-pid-paste")
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            return (focusedValue as! AXUIElement)
        }

        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appValue
        ) == .success, let appValue,
              CFGetTypeID(appValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let appElement = appValue as! AXUIElement
        var nestedFocusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &nestedFocusedValue
        ) == .success, let nestedFocusedValue,
              CFGetTypeID(nestedFocusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (nestedFocusedValue as! AXUIElement)
    }

    private static func captureCmuxTarget(app: NSRunningApplication?) -> CmuxPasteTarget? {
        guard app?.bundleIdentifier == "com.cmuxterm.app" else { return nil }
        guard let cliPath = cmuxCLIPath(app: app) else {
            log("cmux-identify skipped reason=cli-missing")
            return nil
        }
        guard let data = runCmuxProcess(
            executablePath: cliPath,
            arguments: cmuxArguments(["identify", "--no-caller"]),
            operation: "identify"
        ) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let focused = json["focused"] as? [String: Any] else {
            log("cmux-identify failed reason=invalid-json output=\(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }
        guard let surfaceType = focused["surface_type"] as? String,
              surfaceType == "terminal" else {
            log("cmux-identify failed reason=focused-surface-not-terminal surfaceType=\(String(describing: focused["surface_type"]))")
            return nil
        }
        guard let windowRef = focused["window_ref"] as? String,
              let workspaceRef = focused["workspace_ref"] as? String,
              let surfaceRef = focused["surface_ref"] as? String else {
            log("cmux-identify failed reason=missing-refs focused=\(focused)")
            return nil
        }

        return CmuxPasteTarget(
            cliPath: cliPath,
            windowRef: windowRef,
            workspaceRef: workspaceRef,
            surfaceRef: surfaceRef
        )
    }

    private static func sendToCmux(_ text: String, target: CmuxPasteTarget) -> String? {
        guard runCmuxProcess(
            executablePath: target.cliPath,
            arguments: cmuxArguments([
                "send",
                "--window", target.windowRef,
                "--workspace", target.workspaceRef,
                "--surface", target.surfaceRef,
                "--",
                cmuxEscapedText(text)
            ]),
            operation: "send"
        ) != nil else {
            return "cmux-send-failed"
        }

        return nil
    }

    private static func cmuxEscapedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func cmuxCLIPath(app: NSRunningApplication?) -> String? {
        let candidateURLs = [
            app?.bundleURL?.appendingPathComponent("Contents/Resources/bin/cmux"),
            URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")
        ].compactMap { $0 }

        return candidateURLs.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    private static func cmuxArguments(_ arguments: [String]) -> [String] {
        let socketURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux/cmux.sock")
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            return arguments
        }
        return ["--socket", socketURL.path] + arguments
    }

    private struct ProcessOutput {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
    }

    private static func runCmuxProcess(
        executablePath: String,
        arguments: [String],
        operation: String,
        attempts: Int = 2
    ) -> Data? {
        for attempt in 1...attempts {
            guard let result = runProcess(executablePath: executablePath, arguments: arguments) else {
                log("cmux-\(operation) failed attempt=\(attempt) reason=process-launch")
                continue
            }

            if result.exitCode == 0 {
                return result.stdout
            }

            log("cmux-\(operation) failed attempt=\(attempt) mode=direct exit=\(result.exitCode) stderr=\(result.stderr) argv=\(sanitizedCmuxArgv(executablePath: executablePath, arguments: arguments, operation: operation))")
            if let shellResult = runProcess(executablePath: "/bin/zsh", arguments: ["-lc", shellCommand(executablePath: executablePath, arguments: arguments)]) {
                if shellResult.exitCode == 0 {
                    log("cmux-\(operation) recovered attempt=\(attempt) mode=shell")
                    return shellResult.stdout
                }
                log("cmux-\(operation) failed attempt=\(attempt) mode=shell exit=\(shellResult.exitCode) stderr=\(shellResult.stderr)")
            }
            if let launchctlResult = runProcess(
                executablePath: "/bin/launchctl",
                arguments: [
                    "asuser",
                    "\(getuid())",
                    "/bin/zsh",
                    "-lc",
                    shellCommand(executablePath: executablePath, arguments: arguments)
                ]
            ) {
                if launchctlResult.exitCode == 0 {
                    log("cmux-\(operation) recovered attempt=\(attempt) mode=launchctl")
                    return launchctlResult.stdout
                }
                log("cmux-\(operation) failed attempt=\(attempt) mode=launchctl exit=\(launchctlResult.exitCode) stderr=\(launchctlResult.stderr)")
            }
            Thread.sleep(forTimeInterval: 0.06)
        }

        return nil
    }

    private static func shellCommand(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sanitizedCmuxArgv(executablePath: String, arguments: [String], operation: String) -> String {
        var values = [executablePath] + arguments
        if operation == "send", !values.isEmpty {
            values[values.count - 1] = "<text>"
        }
        return values.joined(separator: " ")
    }

    private static func runProcess(executablePath: String, arguments: [String]) -> ProcessOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            process.waitUntilExit()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = error.fileHandleForReading.readDataToEndOfFile()
            return ProcessOutput(
                stdout: stdout,
                stderr: String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            log("process failed executable=\(executablePath) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func log(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-transcribe.log")
    }

    private static func valueChanged(
        from initialValue: String?,
        inserting text: String,
        on element: AXUIElement
    ) -> Bool {
        guard let initialValue else { return false }

        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.04)
            guard let updatedValue = stringAttribute(kAXValueAttribute as CFString, from: element) else {
                return false
            }
            if updatedValue != initialValue && updatedValue.contains(text) {
                return true
            }
        }

        return false
    }

    private static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard
              AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) -> AXError {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
    }

    private static func elementStillExists(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return status == .success
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

private extension String {
    func replacingUTF16Range(_ range: CFRange, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }

        let utf16View = utf16
        guard let lowerUTF16 = utf16View.index(
            utf16View.startIndex,
            offsetBy: range.location,
            limitedBy: utf16View.endIndex
        ), let upperUTF16 = utf16View.index(
            lowerUTF16,
            offsetBy: range.length,
            limitedBy: utf16View.endIndex
        ), let lower = String.Index(lowerUTF16, within: self),
           let upper = String.Index(upperUTF16, within: self) else {
            return nil
        }

        var updated = self
        updated.replaceSubrange(lower..<upper, with: replacement)
        return updated
    }
}

private extension AXError {
    var wireDescription: String {
        switch self {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegal-argument"
        case .invalidUIElement:
            return "invalid-ui-element"
        case .invalidUIElementObserver:
            return "invalid-ui-element-observer"
        case .cannotComplete:
            return "cannot-complete"
        case .attributeUnsupported:
            return "attribute-unsupported"
        case .actionUnsupported:
            return "action-unsupported"
        case .notificationUnsupported:
            return "notification-unsupported"
        case .notImplemented:
            return "not-implemented"
        case .notificationAlreadyRegistered:
            return "notification-already-registered"
        case .notificationNotRegistered:
            return "notification-not-registered"
        case .apiDisabled:
            return "api-disabled"
        case .noValue:
            return "no-value"
        case .parameterizedAttributeUnsupported:
            return "parameterized-attribute-unsupported"
        case .notEnoughPrecision:
            return "not-enough-precision"
        @unknown default:
            return "unknown-\(rawValue)"
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let sendEnterAfterPasteDefaultsKey = "sendEnterAfterPaste"
    private static let headsetControlsEnabledDefaultsKey = "headsetControlsEnabled"
    private static let computerControlsEnabledDefaultsKey = "computerControlsEnabled"
    private static let computerAutoEnableEnabledDefaultsKey = "computerAutoEnableEnabled"
    private static let computerAutoEnablePhraseDefaultsKey = "computerAutoEnablePhrase"
    private static let computerAutoDisablePhraseDefaultsKey = "computerAutoDisablePhrase"
    private static let computerCustomHarnessEnabledDefaultsKey = "computerCustomHarnessEnabled"
    private static let computerHarnessCommandDefaultsKey = "computerHarnessCommand"
    private static let defaultComputerHarnessCommand = "codex --yolo -c 'model_reasoning_effort=\"low\"' e {{prompt}}"
    private static let cleanupEnabledDefaultsKey = "cleanupEnabled"
    private static let backgroundPasteEnabledDefaultsKey = "backgroundPasteEnabled"
    private static let airPodsAutoStopSilenceSeconds: TimeInterval = 1.4
    private static let airPodsAutoStopMinimumSeconds: TimeInterval = 1.2
    private static let airPodsMinimumVoiceRMS: Float = 140
    private static let recoverableRecordingURL = URL(fileURLWithPath: "/tmp/wire-recoverable-recording.wav")
    private static let recoverableRecordingDirectoryURL = URL(fileURLWithPath: "/tmp/wire-recoverable-recordings", isDirectory: true)

    private struct QueuedTranscriptionJob {
        let id: Int
        let audioData: Data
        let recoveryURL: URL?
        let shouldPressReturnAfterPaste: Bool
        let retryASRFailure: Bool
        let wasStartedByAirPods: Bool
        let kind: HotKeyKind?
        let source: String
        let pasteTarget: BackgroundPasteTarget?
    }

    private let state = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private weak var menuBarPopoverController: MenuBarPopoverViewController?
    private var settingsWindow: NSWindow?
    private weak var settingsController: SettingsViewController?
    private var statusSpinnerTimer: Timer?
    private var menuBarFeedbackClearWorkItem: DispatchWorkItem?
    private var menuBarFeedbackTitle: String?
    private var popoverOutsideClickMonitors: [Any] = []
    private var statusSpinnerIndex = 0
    private let statusSpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var hotKeyManager: HotKeyManager!
    private var headsetProbeManager: HeadsetProbeManager!
    private var codexClient: CodexAPIClient!
    private var recorder: AudioRecorder!
    private var recordingStatusTimer: Timer?
    private var recordingStartedAt: Date?
    private var activeRecordingShouldPressReturn = false
    private var activeRecordingStartedByAirPods = false
    private var airPodsSubmitEligible = false
    private var activeRecordingStartedByHeadsetHold = false
    private var activeRecordingSource = ""
    private var activeRecordingPasteTarget: BackgroundPasteTarget?
    private var airPodsMuteStateObserver: NSObjectProtocol?
    private var lastAirPodsMuteToggleAt: Date?
    private var airPodsLastVoiceAt: Date?
    private var airPodsPeakRMS: Float = 0
    private var airPodsLastLevelLogAt: Date?
    private var airPodsAutoStopArmed = false
    private var activeRecordingKind: HotKeyKind?
    private var holdRecordingStartPending = false
    private var stopHoldWhenRecordingStarts = false
    private var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    private var activeTranscriptionJob: QueuedTranscriptionJob?
    private var isProcessingTranscriptionQueue = false
    private var nextTranscriptionJobID = 1
    private var selfTestTranscript: String?
    private var selfTestTranscribeByteCounts: [Int] = []

    private var pendingTranscriptionCount: Int {
        queuedTranscriptionJobs.count + (activeTranscriptionJob == nil ? 0 : 1)
    }

    private var hasPendingTranscriptions: Bool {
        pendingTranscriptionCount > 0 || isProcessingTranscriptionQueue
    }

    private static func appendTranscriptionDebugLog(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-transcribe.log")
    }

    private static func appendHeadsetDebugLog(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-headset.log")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state.sendEnterAfterPaste = UserDefaults.standard.bool(forKey: Self.sendEnterAfterPasteDefaultsKey)
        state.headsetControlsEnabled = (UserDefaults.standard.object(forKey: Self.headsetControlsEnabledDefaultsKey) as? Bool) ?? true
        state.computerControlsEnabled = UserDefaults.standard.bool(forKey: Self.computerControlsEnabledDefaultsKey)
        state.computerAutoEnableEnabled = UserDefaults.standard.bool(forKey: Self.computerAutoEnableEnabledDefaultsKey)
        state.computerAutoEnablePhrase = UserDefaults.standard.string(forKey: Self.computerAutoEnablePhraseDefaultsKey) ?? ""
        state.computerAutoDisablePhrase = UserDefaults.standard.string(forKey: Self.computerAutoDisablePhraseDefaultsKey) ?? ""
        state.computerCustomHarnessEnabled = UserDefaults.standard.bool(forKey: Self.computerCustomHarnessEnabledDefaultsKey)
        state.computerHarnessCommand = UserDefaults.standard.string(forKey: Self.computerHarnessCommandDefaultsKey) ?? Self.defaultComputerHarnessCommand
        state.cleanupEnabled = (UserDefaults.standard.object(forKey: Self.cleanupEnabledDefaultsKey) as? Bool) ?? true
        state.backgroundPasteEnabled = (UserDefaults.standard.object(forKey: Self.backgroundPasteEnabledDefaultsKey) as? Bool) ?? true

        // Initialize components
        codexClient = CodexAPIClient()
        recorder = AudioRecorder()
        recorder.onAudioLevel = { [weak self] rms in
            DispatchQueue.main.async {
                self?.handleRecordingAudioLevel(rms)
            }
        }
        headsetProbeManager = HeadsetProbeManager(
            state: state,
            onTogglePressed: { [weak self] in self?.handleHeadsetTogglePressed() },
            onAirPodsTogglePressed: { [weak self] in self?.handleAirPodsTogglePressed() },
            onAirPodsSubmitPressed: { [weak self] in self?.handleAirPodsSubmitPressed() },
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

        installMainMenu()

        // Menu bar icon
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

        let menuController = MenuBarPopoverViewController(state: state)
        menuController.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBarPopoverController = menuController
        _ = menuController.view

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = menuController

        state.onChange = { [weak self, weak menuController] in
            self?.renderStatusItem()
            menuController?.refresh()
            self?.settingsController?.refresh()
        }
        refreshRecoverableRecordingState()
        hotKeyManager.registerSavedShortcuts()
        headsetProbeManager.restoreSavedState()
        headsetProbeManager.setControlsEnabled(state.headsetControlsEnabled)
        installAirPodsMuteStateHandler()
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
        runHeadsetPathSelfTestIfRequested()
        runDefaultCaptureSelfTestIfRequested()
        runBackgroundPasteSelfTestIfRequested()
        runUISelfTestIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit wire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeKeyWindow), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func closeKeyWindow() {
        if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(nil)
        } else {
            settingsWindow?.performClose(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === settingsWindow else { return }
        settingsWindow = nil
        settingsController = nil
        if !popover.isShown {
            NSApp.setActivationPolicy(.accessory)
        }
    }


    private func runUISelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["WIRE_UI_SELF_TEST"] == "1" else {
            return
        }

        let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIRE_UI_SELF_TEST_DIR"] ?? "/tmp/wire-ui-self-test")
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        state.lastTranscription = "Sample transcription for layout verification."
        state.statusText = "Ready for dictation"
        menuBarPopoverController?.refresh()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }

            if let popoverController = self.menuBarPopoverController {
                popoverController.refresh()
                let popoverView = popoverController.view
                popoverView.layoutSubtreeIfNeeded()
                self.writePNG(from: popoverView, to: outputDirectory.appendingPathComponent("popover.png"))
            }

            self.openSettings()
            self.settingsController?.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                if let settingsWindow = self.settingsWindow, let contentView = self.settingsController?.view {
                    settingsWindow.setFrameOrigin(NSPoint(x: 120, y: 120))
                    settingsWindow.displayIfNeeded()
                    contentView.layoutSubtreeIfNeeded()
                    self.writePNG(from: contentView, to: outputDirectory.appendingPathComponent("settings-general.png"))
                }

                let report = self.makeUISelfTestReport()
                let reportURL = outputDirectory.appendingPathComponent("report.txt")
                try? report.write(to: reportURL, atomically: true, encoding: .utf8)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func writePNG(from view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url)
    }

    private func writePNG(from window: NSWindow, to url: URL) {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            if let contentView = window.contentView {
                writePNG(from: contentView, to: url)
            }
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url)
    }

    private func makeUISelfTestReport() -> String {
        var lines: [String] = []
        lines.append("wire UI self-test report")

        if let popoverView = menuBarPopoverController?.view {
            lines.append("popoverSize=\(Int(popoverView.bounds.width))x\(Int(popoverView.bounds.height))")
        }

        if let settingsWindow {
            lines.append("settingsWindowSize=\(Int(settingsWindow.frame.width))x\(Int(settingsWindow.frame.height))")
            lines.append("settingsTitle=\(settingsWindow.title)")
        }

        if let settingsView = settingsController?.view {
            lines.append("settingsViewSize=\(Int(settingsView.bounds.width))x\(Int(settingsView.bounds.height))")
        }

        settingsController?.collectUISelfTestMetrics(into: &lines)
        if let settingsWindow {
            lines.append("windowFrame=\(settingsWindow.frame)")
        }
        if let contentView = settingsController?.view {
            lines.append("settingsRootFrame=\(contentView.frame)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func runBackgroundPasteSelfTestIfRequested() {
        guard let text = ProcessInfo.processInfo.environment["WIRE_SELF_TEST_BACKGROUND_PASTE_TEXT"] else {
            return
        }

        let outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIRE_SELF_TEST_OUTPUT"] ?? "/tmp/wire-background-paste-self-test.txt")
        let captureDelay = Double(ProcessInfo.processInfo.environment["WIRE_SELF_TEST_BACKGROUND_CAPTURE_DELAY"] ?? "0.7") ?? 0.7
        let pasteDelay = Double(ProcessInfo.processInfo.environment["WIRE_SELF_TEST_BACKGROUND_PASTE_DELAY"] ?? "2.5") ?? 2.5

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, captureDelay) * 1_000_000_000))
            let target = BackgroundPaste.captureIfTrusted()
            let capturedSummary = target?.summary ?? "none"
            Self.appendTranscriptionDebugLog("background-self-test captured target=\(capturedSummary)")

            try? await Task.sleep(nanoseconds: UInt64(max(0, pasteDelay) * 1_000_000_000))
            state.transcriptionStage = .done
            state.lastTranscription = text
            let frontmostBeforePaste = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            let result = pasteTranscript(text, target: target, pressReturnAfterPaste: false)
            let frontmostAfterPaste = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            let lines = [
                "target=\(capturedSummary)",
                "frontmostBeforePaste=\(frontmostBeforePaste)",
                "frontmostAfterPaste=\(frontmostAfterPaste)",
                "result=\(result)",
                "text=\(text)"
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
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
            activeRecordingStartedByHeadsetHold = false
            activeRecordingSource = ""
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

    private func runDefaultCaptureSelfTestIfRequested() {
        guard let rawSeconds = ProcessInfo.processInfo.environment["WIRE_SELF_TEST_DEFAULT_CAPTURE_SECONDS"],
              let seconds = Double(rawSeconds) else { return }
        let outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIRE_SELF_TEST_OUTPUT"] ?? "/tmp/wire-default-capture-self-test.txt")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            do {
                try recorder.start()
            } catch {
                try? "started=false\nerror=\(error.localizedDescription)\n".write(to: outputURL, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(max(0.2, seconds) * 1_000_000_000))
            let data = recorder.stop()
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

    private func runHeadsetPathSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["WIRE_SELF_TEST_HEADSET_PATHS"] == "1" else { return }
        let outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIRE_SELF_TEST_OUTPUT"] ?? "/tmp/wire-headset-path-self-test.txt")

        Task { @MainActor in
            selfTestTranscript = "synthetic transcript"
            let audio = Self.syntheticSpeechLikeWavData(duration: 2.0)
            let hold = await runSyntheticHeadsetPath(name: "hold") {
                self.recorder.useSyntheticRecordingData(audio)
                self.handleHeadsetHoldPressed()
                await self.waitForSelfTestCondition { self.recorder.hasActiveRecording }
                self.handleHeadsetHoldReleased()
            }
            let toggle = await runSyntheticHeadsetPath(name: "toggle") {
                self.recorder.useSyntheticRecordingData(audio)
                self.handleHeadsetTogglePressed()
                await self.waitForSelfTestCondition { self.recorder.hasActiveRecording }
                self.handleHeadsetTogglePressed()
            }

            let lines = [
                "hold=\(hold)",
                "toggle=\(toggle)",
                "transcribeByteCounts=\(selfTestTranscribeByteCounts.map(String.init).joined(separator: ","))"
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private func runSyntheticHeadsetPath(name: String, action: @escaping () async -> Void) async -> String {
        state.statusText = "Self-testing \(name)"
        state.transcriptionStage = .idle
        state.isBusy = false
        state.lastTranscription = ""
        selfTestTranscribeByteCounts.removeAll()

        await action()
        await waitForSelfTestCondition {
            !self.state.isBusy
                && !self.recorder.hasActiveRecording
                && self.state.transcriptionStage != .recording
                && self.state.transcriptionStage != .transcribing
        }

        let stage: String
        switch state.transcriptionStage {
        case .idle: stage = "idle"
        case .recording: stage = "recording"
        case .transcribing: stage = "transcribing"
        case .done: stage = "done"
        case .error(let message): stage = "error:\(message)"
        }
        return "stage=\(stage) status=\(state.statusText) transcript=\(state.lastTranscription)"
    }

    @MainActor
    private func waitForSelfTestCondition(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func syntheticSpeechLikeWavData(duration: Double) -> Data {
        let sampleRate = 16_000
        let sampleCount = max(1, Int(duration * Double(sampleRate)))
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let envelope = 0.55 + 0.35 * sin(2.0 * Double.pi * 3.0 * t)
            let signal = sin(2.0 * Double.pi * 220.0 * t) + 0.35 * sin(2.0 * Double.pi * 440.0 * t)
            let sample = Int16(max(-24_000, min(24_000, Int(signal * envelope * 10_000))))
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        appendLittleEndianUInt32(UInt32(36 + pcm.count), to: &data)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendLittleEndianUInt32(16, to: &data)
        appendLittleEndianUInt16(1, to: &data)
        appendLittleEndianUInt16(1, to: &data)
        appendLittleEndianUInt32(UInt32(sampleRate), to: &data)
        appendLittleEndianUInt32(UInt32(sampleRate * 2), to: &data)
        appendLittleEndianUInt16(2, to: &data)
        appendLittleEndianUInt16(16, to: &data)
        data.append("data".data(using: .ascii)!)
        appendLittleEndianUInt32(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func appendLittleEndianUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
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

    @objc func openSettings() {
        closePopover()
        if settingsWindow == nil {
            let controller = SettingsViewController(
                state: state,
                hotKeyManager: hotKeyManager,
                headsetProbeManager: headsetProbeManager
            )
            settingsController = controller
            _ = controller.view

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentViewController = controller
            window.minSize = NSSize(width: 500, height: 320)
            window.backgroundColor = .windowBackgroundColor
            window.toolbar = controller.makeToolbar()
            window.toolbarStyle = .preference
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
            controller.resizeWindowForSelectedPane()
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.refresh()
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
        handleTranscribe(source: "keyboard-toggle")
    }

    private func handleHeadsetTogglePressed() {
        handleTranscribe(sendReturnAfterPasteEligible: true, source: "headset-toggle")
    }

    private func handleAirPodsTogglePressed() {
        handleTranscribe(useAirPodsInput: true, startedByAirPods: true, source: "airpods-toggle")
    }

    private func handleAirPodsSubmitPressed() {
        guard !recorder.hasActiveRecording, state.transcriptionStage != .transcribing else {
            Self.appendHeadsetDebugLog("airpods submit ignored recording=\(recorder.hasActiveRecording) stage=\(state.transcriptionStage)")
            return
        }
        guard airPodsSubmitEligible else {
            Self.appendHeadsetDebugLog("airpods submit ignored reason=no-airpods-transcript")
            state.statusText = "Dictate with AirPods first"
            showMenuBarFeedback("No transcript")
            return
        }
        airPodsSubmitEligible = false
        Self.appendHeadsetDebugLog("airpods submit press-return")
        pressReturnKey()
        state.statusText = "Submitted"
        showMenuBarFeedback("Submitted")
    }

    private func installAirPodsMuteStateHandler() {
        guard #available(macOS 14.0, *) else {
            Self.appendHeadsetDebugLog("airpods mute-state unavailable reason=macos-version")
            return
        }

        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] isMuted in
                Self.appendHeadsetDebugLog("airpods mute-state handler muted=\(isMuted)")
                DispatchQueue.main.async {
                    self?.handleAirPodsMuteStateToggle(isMuted: isMuted)
                }
                return true
            }
            airPodsMuteStateObserver = NotificationCenter.default.addObserver(
                forName: AVAudioApplication.inputMuteStateChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Self.appendHeadsetDebugLog("airpods mute-state notification=\(notification.name.rawValue)")
                self?.handleAirPodsMuteStateToggle(isMuted: nil)
            }
            Self.appendHeadsetDebugLog("airpods mute-state installed")
        } catch {
            Self.appendHeadsetDebugLog("airpods mute-state install failed error=\(error.localizedDescription)")
        }
    }

    private func handleAirPodsMuteStateToggle(isMuted: Bool?) {
        guard recorder.hasActiveRecording, activeRecordingStartedByAirPods else {
            Self.appendHeadsetDebugLog("airpods mute-state ignored active=\(recorder.hasActiveRecording) startedByAirPods=\(activeRecordingStartedByAirPods) muted=\(String(describing: isMuted))")
            return
        }
        if let recordingStartedAt, Date().timeIntervalSince(recordingStartedAt) < 1.5 {
            Self.appendHeadsetDebugLog("airpods mute-state ignored reason=arming muted=\(String(describing: isMuted))")
            return
        }
        if let lastAirPodsMuteToggleAt, Date().timeIntervalSince(lastAirPodsMuteToggleAt) < 0.45 {
            Self.appendHeadsetDebugLog("airpods mute-state ignored reason=debounce muted=\(String(describing: isMuted))")
            return
        }
        lastAirPodsMuteToggleAt = Date()
        Self.appendHeadsetDebugLog("airpods mute-state stop muted=\(String(describing: isMuted))")
        stopAndTranscribe()
    }

    private func handleRecordingAudioLevel(_ rms: Float) {
        guard recorder.hasActiveRecording,
              activeRecordingStartedByAirPods,
              activeRecordingSource == "airpods-toggle",
              let recordingStartedAt else {
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(recordingStartedAt)
        airPodsPeakRMS = max(airPodsPeakRMS, rms)
        if airPodsLastLevelLogAt == nil || now.timeIntervalSince(airPodsLastLevelLogAt!) >= 1 {
            airPodsLastLevelLogAt = now
            Self.appendHeadsetDebugLog("airpods level rms=\(String(format: "%.1f", rms)) peak=\(String(format: "%.1f", airPodsPeakRMS)) elapsed=\(String(format: "%.2f", elapsed)) armed=\(airPodsAutoStopArmed)")
        }

        let voiceThreshold = max(Self.airPodsMinimumVoiceRMS, airPodsPeakRMS * 0.42)
        if rms >= voiceThreshold {
            airPodsLastVoiceAt = now
            if !airPodsAutoStopArmed, elapsed >= Self.airPodsAutoStopMinimumSeconds {
                airPodsAutoStopArmed = true
                Self.appendHeadsetDebugLog("airpods auto-stop armed rms=\(String(format: "%.1f", rms)) peak=\(String(format: "%.1f", airPodsPeakRMS)) threshold=\(String(format: "%.1f", voiceThreshold)) elapsed=\(String(format: "%.2f", elapsed))")
            }
            return
        }

        guard airPodsAutoStopArmed,
              elapsed >= Self.airPodsAutoStopMinimumSeconds,
              let lastVoiceAt = airPodsLastVoiceAt,
              now.timeIntervalSince(lastVoiceAt) >= Self.airPodsAutoStopSilenceSeconds else {
            return
        }

        Self.appendHeadsetDebugLog("airpods auto-stop silence rms=\(String(format: "%.1f", rms)) peak=\(String(format: "%.1f", airPodsPeakRMS)) threshold=\(String(format: "%.1f", voiceThreshold)) elapsed=\(String(format: "%.2f", elapsed)) silence=\(String(format: "%.2f", now.timeIntervalSince(lastVoiceAt)))")
        playAirPodsRecordingEndedFeedback()
        stopAndTranscribe()
    }

    private func playAirPodsRecordingEndedFeedback() {
        NSSound(named: "Tink")?.play()
    }

    private func handleHoldHotKeyPressed() {
        startRecording(status: "Recording… release hold shortcut to transcribe", kind: .hold, source: "keyboard-hold")
    }

    private func handleHeadsetHoldPressed() {
        Self.appendHeadsetDebugLog("app hold-pressed")
        startRecording(
            status: "Recording… release headset button to transcribe",
            kind: .hold,
            useBuiltInInput: true,
            sendReturnAfterPasteEligible: true,
            startedByHeadsetHold: true,
            source: "headset-hold"
        )
    }

    private func handleHoldHotKeyReleased() {
        if recorder.hasActiveRecording, activeRecordingKind == .hold {
            Self.appendHeadsetDebugLog("app hold-release stop active=true kind=hold")
            stopAndTranscribe()
        } else if holdRecordingStartPending {
            Self.appendHeadsetDebugLog("app hold-release queued pending-start active=\(recorder.hasActiveRecording) kind=\(String(describing: activeRecordingKind))")
            stopHoldWhenRecordingStarts = true
        } else {
            Self.appendHeadsetDebugLog("app hold-release ignored active=\(recorder.hasActiveRecording) kind=\(String(describing: activeRecordingKind)) pending=false")
        }
    }

    private func handleHeadsetHoldReleased() {
        if recorder.hasActiveRecording {
            Self.appendHeadsetDebugLog("app headset-hold-release stop active=true kind=\(String(describing: activeRecordingKind)) startedByHeadsetHold=\(activeRecordingStartedByHeadsetHold) source=\(activeRecordingSource)")
            stopAndTranscribe()
        } else {
            handleHoldHotKeyReleased()
        }
    }

    private func handleTranscribe(
        useBuiltInInput: Bool = false,
        useAirPodsInput: Bool = false,
        sendReturnAfterPasteEligible: Bool = false,
        startedByAirPods: Bool = false,
        source: String
    ) {
        if recorder.hasActiveRecording {
            Self.appendTranscriptionDebugLog("toggle-stop source=\(source) activeKind=\(String(describing: activeRecordingKind)) activeSource=\(activeRecordingSource)")
            stopAndTranscribe()
        } else {
            startRecording(
                status: "Recording… press toggle shortcut again to stop",
                kind: .toggle,
                useBuiltInInput: useBuiltInInput,
                useAirPodsInput: useAirPodsInput,
                sendReturnAfterPasteEligible: sendReturnAfterPasteEligible,
                startedByAirPods: startedByAirPods,
                source: source
            )
        }
    }

    private func startRecording(
        status: String,
        kind: HotKeyKind,
        useBuiltInInput: Bool = false,
        useAirPodsInput: Bool = false,
        sendReturnAfterPasteEligible: Bool = false,
        startedByAirPods: Bool = false,
        startedByHeadsetHold: Bool = false,
        source: String
    ) {
        let pasteTarget = state.backgroundPasteEnabled ? BackgroundPaste.captureIfTrusted() : nil

        if kind == .hold {
            holdRecordingStartPending = true
            stopHoldWhenRecordingStarts = false
            Self.appendHeadsetDebugLog("app start-hold pending=true source=\(source)")
        }

        Task { @MainActor in
            guard !recorder.hasActiveRecording else {
                Self.appendTranscriptionDebugLog("start ignored source=\(source) kind=\(kind) reason=already-active activeKind=\(String(describing: activeRecordingKind)) activeSource=\(activeRecordingSource)")
                clearPendingHoldStartIfNeeded(kind: kind)
                return
            }

            guard await ensureMicrophonePermission() else {
                clearPendingHoldStartIfNeeded(kind: kind)
                state.statusText = "Enable Microphone permission for wire"
                if hasPendingTranscriptions {
                    state.isBusy = true
                } else {
                    state.transcriptionStage = .error("Microphone permission missing")
                    state.isBusy = false
                }
                openMicrophoneSettings()
                return
            }

            state.transcriptionStage = .recording
            state.statusText = status
            state.isBusy = true

            var inputDeviceID: AudioDeviceID?
            do {
                if useAirPodsInput {
                    inputDeviceID = try DefaultAudioInputOverride.airPodsInputDeviceID() ?? DefaultAudioInputOverride.builtInInputDeviceID()
                } else if useBuiltInInput {
                    inputDeviceID = try DefaultAudioInputOverride.builtInInputDeviceID()
                }
                try recorder.start(inputDeviceID: inputDeviceID)
                activeRecordingKind = kind
                activeRecordingShouldPressReturn = sendReturnAfterPasteEligible
                activeRecordingStartedByAirPods = startedByAirPods
                activeRecordingStartedByHeadsetHold = startedByHeadsetHold
                activeRecordingSource = source
                activeRecordingPasteTarget = pasteTarget
                airPodsLastVoiceAt = startedByAirPods ? Date() : nil
                airPodsPeakRMS = 0
                airPodsLastLevelLogAt = nil
                airPodsAutoStopArmed = false
                let inputDeviceName = inputDeviceID.flatMap { DefaultAudioInputOverride.audioDeviceName($0) } ?? "default"
                let pasteTargetSummary = state.backgroundPasteEnabled ? (pasteTarget?.summary ?? "none") : "disabled"
                Self.appendTranscriptionDebugLog("start source=\(source) kind=\(kind) builtIn=\(useBuiltInInput) airPodsInput=\(useAirPodsInput) inputDevice=\(inputDeviceName) headsetHold=\(startedByHeadsetHold) airpods=\(startedByAirPods) pasteTarget=\(pasteTargetSummary)")
                let shouldStopImmediately = kind == .hold && stopHoldWhenRecordingStarts
                if kind == .hold {
                    Self.appendHeadsetDebugLog("app start-hold active=true stopImmediately=\(shouldStopImmediately) source=\(source)")
                }
                clearPendingHoldStartIfNeeded(kind: kind)
                startRecordingStatusTimer()
                if shouldStopImmediately {
                    stopAndTranscribe()
                }
            } catch {
                clearPendingHoldStartIfNeeded(kind: kind)
                activeRecordingPasteTarget = nil
                state.statusText = "Could not start recording: \(error.localizedDescription)"
                Self.appendTranscriptionDebugLog("start failed source=\(source) kind=\(kind) error=\(error.localizedDescription)")
                if hasPendingTranscriptions {
                    state.isBusy = true
                } else {
                    state.transcriptionStage = .error(error.localizedDescription)
                    state.isBusy = false
                }
            }
        }
    }

    private func clearPendingHoldStartIfNeeded(kind: HotKeyKind) {
        guard kind == .hold else { return }
        holdRecordingStartPending = false
        stopHoldWhenRecordingStarts = false
    }

    private func stopAndTranscribe() {
        Task { @MainActor in
            guard recorder.hasActiveRecording else {
                Self.appendTranscriptionDebugLog("stop ignored reason=no-active-recording kind=\(String(describing: activeRecordingKind))")
                return
            }

            let audioData = recorder.stop()
            let shouldPressReturnAfterPaste = activeRecordingShouldPressReturn && state.sendEnterAfterPaste
            let wasStartedByAirPods = activeRecordingStartedByAirPods
            let wasStartedByHeadsetHold = activeRecordingStartedByHeadsetHold
            let stoppedRecordingKind = activeRecordingKind
            let stoppedRecordingSource = activeRecordingSource
            let pasteTarget = activeRecordingPasteTarget
            stopRecordingStatusTimer()
            activeRecordingKind = nil
            activeRecordingShouldPressReturn = false
            activeRecordingStartedByAirPods = false
            activeRecordingStartedByHeadsetHold = false
            activeRecordingSource = ""
            activeRecordingPasteTarget = nil
            airPodsLastVoiceAt = nil
            airPodsPeakRMS = 0
            airPodsLastLevelLogAt = nil
            airPodsAutoStopArmed = false

            guard let data = audioData, data.count > 1000 else {
                Self.appendTranscriptionDebugLog("skip source=\(stoppedRecordingSource) kind=\(String(describing: stoppedRecordingKind)) reason=too-short bytes=\(audioData?.count ?? 0)")
                finishStoppedRecordingWithoutTranscription(
                    status: "Recording too short, try again",
                    stage: .error("Recording too short")
                )
                return
            }

            if let stats = wavStats(data) {
                Self.appendTranscriptionDebugLog(
                    "stop source=\(stoppedRecordingSource) kind=\(String(describing: stoppedRecordingKind)) bytes=\(data.count) duration=\(String(format: "%.3f", stats.duration)) rms=\(String(format: "%.1f", stats.rms)) peak=\(stats.peak) airpods=\(wasStartedByAirPods)"
                )
            } else {
                Self.appendTranscriptionDebugLog("stop source=\(stoppedRecordingSource) kind=\(String(describing: stoppedRecordingKind)) bytes=\(data.count) stats=unavailable airpods=\(wasStartedByAirPods)")
            }

            guard hasCapturedAudio(data) else {
                Self.appendTranscriptionDebugLog("skip source=\(stoppedRecordingSource) kind=\(String(describing: stoppedRecordingKind)) reason=no-captured-audio bytes=\(data.count)")
                finishStoppedRecordingWithoutTranscription(
                    status: "No microphone audio captured",
                    stage: .error("No microphone audio captured")
                )
                return
            }

            let shouldAlwaysAttemptTranscription = wasStartedByAirPods || wasStartedByHeadsetHold || stoppedRecordingKind == .hold
            guard shouldAlwaysAttemptTranscription || isLikelySpeechRecording(data) else {
                Self.appendTranscriptionDebugLog("skip source=\(stoppedRecordingSource) kind=\(String(describing: stoppedRecordingKind)) reason=speech-gate bytes=\(data.count)")
                finishStoppedRecordingWithoutTranscription(status: "Ready", stage: .idle)
                return
            }

            enqueueTranscriptionJob(
                audioData: data,
                shouldPressReturnAfterPaste: shouldPressReturnAfterPaste,
                retryASRFailure: wasStartedByAirPods,
                wasStartedByAirPods: wasStartedByAirPods,
                kind: stoppedRecordingKind,
                source: stoppedRecordingSource,
                pasteTarget: pasteTarget
            )
        }
    }

    private func finishStoppedRecordingWithoutTranscription(status: String, stage: TranscriptionStage) {
        if hasPendingTranscriptions {
            refreshTranscriptionQueueStatus()
            return
        }

        state.statusText = status
        state.transcriptionStage = stage
        state.isBusy = recorder.hasActiveRecording
    }

    private func enqueueTranscriptionJob(
        audioData: Data,
        shouldPressReturnAfterPaste: Bool,
        retryASRFailure: Bool,
        wasStartedByAirPods: Bool,
        kind: HotKeyKind?,
        source: String,
        pasteTarget: BackgroundPasteTarget? = nil,
        recoveryURL existingRecoveryURL: URL? = nil
    ) {
        let id = nextTranscriptionJobID
        nextTranscriptionJobID += 1
        let recoveryURL = existingRecoveryURL ?? writeRecoverableRecording(audioData, jobID: id)
        let job = QueuedTranscriptionJob(
            id: id,
            audioData: audioData,
            recoveryURL: recoveryURL,
            shouldPressReturnAfterPaste: shouldPressReturnAfterPaste,
            retryASRFailure: retryASRFailure,
            wasStartedByAirPods: wasStartedByAirPods,
            kind: kind,
            source: source,
            pasteTarget: pasteTarget
        )

        queuedTranscriptionJobs.append(job)
        refreshRecoverableRecordingState()
        state.isBusy = true
        if !recorder.hasActiveRecording {
            state.transcriptionStage = .transcribing
            state.statusText = queuedTranscriptionJobs.count == 1 && activeTranscriptionJob == nil
                ? "Loading… uploading \(audioData.count / 1024) KB"
                : transcriptionQueueStatusText()
        }
        Self.appendTranscriptionDebugLog("enqueue id=\(id) source=\(source) kind=\(String(describing: kind)) bytes=\(audioData.count) pending=\(pendingTranscriptionCount) pasteTarget=\(pasteTarget?.summary ?? "none")")
        startTranscriptionQueueWorkerIfNeeded()
    }

    private func startTranscriptionQueueWorkerIfNeeded() {
        guard !isProcessingTranscriptionQueue else { return }
        isProcessingTranscriptionQueue = true
        Task { @MainActor in
            await processTranscriptionQueue()
        }
    }

    private func processTranscriptionQueue() async {
        while !queuedTranscriptionJobs.isEmpty {
            let job = queuedTranscriptionJobs.removeFirst()
            activeTranscriptionJob = job
            await processTranscriptionJob(job)
            activeTranscriptionJob = nil
        }

        isProcessingTranscriptionQueue = false
        refreshRecoverableRecordingState()
        if recorder.hasActiveRecording {
            state.transcriptionStage = .recording
            state.isBusy = true
        } else {
            state.isBusy = false
            if state.transcriptionStage == .transcribing {
                state.transcriptionStage = state.lastTranscription.isEmpty ? .idle : .done
                state.statusText = state.lastTranscription.isEmpty ? "Ready" : "Done"
            }
        }
    }

    private func processTranscriptionJob(_ job: QueuedTranscriptionJob) async {
        if !recorder.hasActiveRecording {
            state.transcriptionStage = .transcribing
            state.statusText = "Loading… uploading \(job.audioData.count / 1024) KB"
        }
        do {
            let rawText = try await transcribe(job.audioData, retryASRFailure: job.retryASRFailure)

            var finalText = rawText
            if state.cleanupEnabled {
                if !recorder.hasActiveRecording {
                    state.statusText = "Cleaning up…"
                }
                do {
                    finalText = try await codexClient.cleanup(text: rawText)
                    Self.appendTranscriptionDebugLog("cleanup id=\(job.id) rawChars=\(rawText.count) cleanedChars=\(finalText.count)")
                } catch {
                    Self.appendTranscriptionDebugLog("cleanup-failed id=\(job.id) error=\(error.localizedDescription) falling back to raw")
                    finalText = rawText
                }
            }

            state.lastTranscription = finalText
            if let recoveryURL = job.recoveryURL {
                try? FileManager.default.removeItem(at: recoveryURL)
            }
            refreshRecoverableRecordingState()
            if !recorder.hasActiveRecording {
                state.transcriptionStage = .done
                state.statusText = queuedTranscriptionJobs.isEmpty ? "Done" : transcriptionQueueStatusText()
            }
            if job.wasStartedByAirPods {
                airPodsSubmitEligible = true
            }
            let copiedToClipboard = Clipboard.copy(finalText)
            Self.appendTranscriptionDebugLog("done id=\(job.id) source=\(job.source) kind=\(String(describing: job.kind)) textChars=\(finalText.count) clipboard=\(copiedToClipboard) remaining=\(queuedTranscriptionJobs.count)")

            if !handleComputerTranscript(finalText) {
                pasteTranscript(
                    finalText,
                    target: job.pasteTarget,
                    pressReturnAfterPaste: job.shouldPressReturnAfterPaste
                )
            }

            let pasteDelay: UInt64 = job.shouldPressReturnAfterPaste ? 260_000_000 : 120_000_000
            try? await Task.sleep(nanoseconds: pasteDelay)
        } catch {
            Self.appendTranscriptionDebugLog("error id=\(job.id) source=\(job.source) kind=\(String(describing: job.kind)) error=\(error.localizedDescription)")
            if !recorder.hasActiveRecording {
                if isASRBackendFailure(error) {
                    state.statusText = "Error: speech recognition failed. Try again."
                    state.transcriptionStage = .error("Speech recognition failed")
                } else {
                    state.statusText = "Error: \(error.localizedDescription)"
                    state.transcriptionStage = .error(error.localizedDescription)
                }
            }
            refreshRecoverableRecordingState()
        }

        if !recorder.hasActiveRecording, !queuedTranscriptionJobs.isEmpty {
            refreshTranscriptionQueueStatus()
        }
    }

    private func refreshTranscriptionQueueStatus() {
        state.isBusy = recorder.hasActiveRecording || hasPendingTranscriptions
        guard !recorder.hasActiveRecording, hasPendingTranscriptions else { return }
        state.transcriptionStage = .transcribing
        state.statusText = transcriptionQueueStatusText()
    }

    private func transcriptionQueueStatusText() -> String {
        let count = pendingTranscriptionCount
        if count <= 1 {
            return "Loading… transcribing"
        }
        return "Loading… transcribing (\(count) pending)"
    }

    private func writeRecoverableRecording(_ data: Data, jobID: Int) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: Self.recoverableRecordingDirectoryURL,
                withIntermediateDirectories: true
            )
            let filename = String(format: "wire-%06d-%@.wav", jobID, UUID().uuidString)
            let url = Self.recoverableRecordingDirectoryURL.appendingPathComponent(filename)
            try data.write(to: url)
            return url
        } catch {
            Self.appendTranscriptionDebugLog("recoverable write failed id=\(jobID) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func refreshRecoverableRecordingState() {
        state.hasRecoverableRecording = oldestRecoverableRecordingURL() != nil
    }

    private func oldestRecoverableRecordingURL() -> URL? {
        var candidates: [URL] = []
        if FileManager.default.fileExists(atPath: Self.recoverableRecordingURL.path) {
            candidates.append(Self.recoverableRecordingURL)
        }
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: Self.recoverableRecordingDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "wav" })
        }

        return candidates.sorted { lhs, rhs in
            recoverableRecordingDate(lhs) < recoverableRecordingDate(rhs)
        }.first
    }

    private func recoverableRecordingDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate
            ?? values?.contentModificationDate
            ?? .distantPast
    }

    private func transcribe(_ data: Data, retryASRFailure: Bool) async throws -> String {
        if let selfTestTranscript {
            selfTestTranscribeByteCounts.append(data.count)
            return selfTestTranscript
        }

        var attempt = 0
        while true {
            do {
                return try await codexClient.transcribe(audioData: data)
            } catch {
                if let delay = retryDelayForTemporaryTranscriptionFailure(error), attempt < 3 {
                    attempt += 1
                    let boundedDelay = min(max(delay, 5), 90)
                    await MainActor.run {
                        state.statusText = "Transcription busy, retrying in \(Int(boundedDelay))s..."
                    }
                    Self.appendTranscriptionDebugLog("retry reason=temporary-unavailable attempt=\(attempt) delay=\(Int(boundedDelay))")
                    try await Task.sleep(nanoseconds: UInt64(boundedDelay * 1_000_000_000))
                    continue
                }

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
    }

    private func retryDelayForTemporaryTranscriptionFailure(_ error: Error) -> TimeInterval? {
        guard case AppError.transcriptionFailed(let message) = error else { return nil }
        guard message.contains("HTTP 429")
                || message.localizedCaseInsensitiveContains("temporarily unavailable") else {
            return nil
        }

        let marker = "\"retry_after_seconds\":"
        if let markerRange = message.range(of: marker) {
            let suffix = message[markerRange.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let seconds = TimeInterval(String(digits)) {
                return seconds
            }
        }
        return 30
    }

    private func isASRBackendFailure(_ error: Error) -> Bool {
        guard case AppError.transcriptionFailed(let message) = error else { return false }
        return message.contains("HTTP 500") && message.localizedCaseInsensitiveContains("ASR")
    }

    @objc func retryLastRecordingObjc() {
        retryLastRecording()
    }

    private func retryLastRecording() {
        Task { @MainActor in
            guard !recorder.hasActiveRecording, !hasPendingTranscriptions else { return }
            guard let recoveryURL = oldestRecoverableRecordingURL(),
                  let data = try? Data(contentsOf: recoveryURL),
                  data.count > 1000 else {
                state.statusText = "No saved recording to retry"
                refreshRecoverableRecordingState()
                return
            }

            state.transcriptionStage = .transcribing
            state.statusText = "Retrying saved recording..."
            Self.appendTranscriptionDebugLog("retry-last enqueue url=\(recoveryURL.path) bytes=\(data.count)")
            enqueueTranscriptionJob(
                audioData: data,
                shouldPressReturnAfterPaste: false,
                retryASRFailure: false,
                wasStartedByAirPods: false,
                kind: nil,
                source: "retry-last",
                recoveryURL: recoveryURL
            )
        }
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
        return stats.duration > 0.1 && (stats.rms >= 8 || stats.peak >= 80)
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

    @discardableResult
    private func pasteTranscript(
        _ text: String,
        target: BackgroundPasteTarget?,
        pressReturnAfterPaste: Bool
    ) -> String {
        if let target,
           target.bundleIdentifier == "com.cmuxterm.app",
           target.cmuxTarget == nil,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleIdentifier {
            Self.appendTranscriptionDebugLog("background-paste skipped reason=cmux-frontmost target=\(target.summary)")
            typeText(text, pressReturnAfterPaste: pressReturnAfterPaste)
            state.statusText = "Pasted to CMUX"
            showMenuBarFeedback("Pasted")
            return "cmux-foreground"
        }

        if let target {
            switch BackgroundPaste.insert(text, into: target) {
            case .inserted(let method):
                Self.appendTranscriptionDebugLog("background-paste success method=\(method) target=\(target.summary)")
                state.statusText = "Pasted to original app"
                showMenuBarFeedback("Pasted")
                if pressReturnAfterPaste {
                    Self.appendTranscriptionDebugLog("background-paste return skipped reason=background-key-events-unsupported target=\(target.summary)")
                }
                return "background:\(method)"
            case .failed(let reason):
                Self.appendTranscriptionDebugLog("background-paste failed reason=\(reason) target=\(target.summary)")
            case .failedWithoutFallback(let reason):
                Self.appendTranscriptionDebugLog("background-paste failed-no-fallback reason=\(reason) target=\(target.summary)")
                state.statusText = target.bundleIdentifier == "com.cmuxterm.app"
                    ? "Copied, CMUX paste failed"
                    : "Copied, background paste failed"
                showMenuBarFeedback("Copied")
                return "background-failed:\(reason)"
            }
        } else {
            Self.appendTranscriptionDebugLog("background-paste skipped reason=no-target")
        }

        typeText(text, pressReturnAfterPaste: pressReturnAfterPaste)
        state.statusText = "Pasted to current app"
        showMenuBarFeedback("Pasted here")
        return "foreground-fallback"
    }

    private func typeText(_ text: String, pressReturnAfterPaste: Bool) {
        guard requestAccessibilityPermission(prompt: false) else {
            state.statusText = "Enable Accessibility permission for wire to paste"
            openAccessibilitySettings()
            return
        }

        Clipboard.copy(text)

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

        let disablePhrase = state.computerAutoDisablePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.computerAutoEnableEnabled,
           normalizedPhrase(disablePhrase).split(separator: " ").count >= 2,
           fuzzyMatches(text, disablePhrase) {
            setComputerControlsEnabled(false)
            state.statusText = "Computer mode disabled"
            showMenuBarFeedback("Mode off")
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

    func setComputerAutoDisablePhrase(_ phrase: String) {
        UserDefaults.standard.set(phrase, forKey: Self.computerAutoDisablePhraseDefaultsKey)
        state.computerAutoDisablePhrase = phrase
        state.statusText = phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Auto disable phrase cleared"
            : "Auto disable phrase saved"
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

    func setCleanupEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.cleanupEnabledDefaultsKey)
        state.cleanupEnabled = enabled
        state.statusText = enabled ? "Cleanup enabled" : "Cleanup disabled"
    }

    func setBackgroundPasteEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.backgroundPasteEnabledDefaultsKey)
        state.backgroundPasteEnabled = enabled
        state.statusText = enabled ? "Paste to source app enabled" : "Pasting to active app only"
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
    var hasRecoverableRecording = AppState.recoverableRecordingExistsOnDisk() { didSet { onChange?() } }
    var transcriptionStage: TranscriptionStage = .idle { didSet { onChange?() } }
    var sendEnterAfterPaste = false { didSet { onChange?() } }
    var headsetControlsEnabled = true { didSet { onChange?() } }
    var computerControlsEnabled = false { didSet { onChange?() } }
    var computerAutoEnableEnabled = false { didSet { onChange?() } }
    var computerAutoEnablePhrase = "" { didSet { onChange?() } }
    var computerAutoDisablePhrase = "" { didSet { onChange?() } }
    var computerCustomHarnessEnabled = false { didSet { onChange?() } }
    var computerHarnessCommand = "" { didSet { onChange?() } }
    var computerCommandRunning = false { didSet { onChange?() } }
    var cleanupEnabled = true { didSet { onChange?() } }
    var backgroundPasteEnabled = true { didSet { onChange?() } }

    private static func recoverableRecordingExistsOnDisk() -> Bool {
        if FileManager.default.fileExists(atPath: "/tmp/wire-recoverable-recording.wav") {
            return true
        }
        let directory = URL(fileURLWithPath: "/tmp/wire-recoverable-recordings", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return urls.contains { $0.pathExtension.lowercased() == "wav" }
    }
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

    static func airPodsInputDeviceID() -> AudioDeviceID? {
        audioDeviceIDs().first { deviceID in
            audioStreamCount(deviceID, scope: kAudioDevicePropertyScopeInput) > 0
                && isAirPodsInput(deviceID)
        }
    }

    static func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
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

    private static func isBuiltInInput(_ deviceID: AudioDeviceID) -> Bool {
        let name = (audioDeviceName(deviceID) ?? "").lowercased()
        if name.contains("macbook")
            || name.contains("built-in microphone")
            || name.contains("built in microphone")
            || name.contains("internal microphone") {
            return true
        }
        return false
    }

    private static func isAirPodsInput(_ deviceID: AudioDeviceID) -> Bool {
        let name = (audioDeviceName(deviceID) ?? "").lowercased()
        guard name.contains("airpods") else { return false }
        let transport = audioTransport(deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeUnknown
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

    static func audioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
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

    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
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

    private struct InputReportRegistration {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let length: CFIndex
        let scheduled: Bool
    }

    private static let modeDefaultsKey = "headsetButtonMode"
    private static let airPodsControlDefaultsKey = "airPodsMacMicControlEnabled"
    private static let playPauseUsage: UInt32 = 0xcd
    private static let nextTrackUsage: UInt32 = 0xb5
    private static let longPressThreshold: TimeInterval = 0.45
    private static let keyboardMediaKeySuppressWindow: TimeInterval = 0.35
    private static let nxKeyTypePlay: Int = 16
    private static let nxKeyTypeNext: Int = 17
    private static let nxKeyTypePrevious: Int = 18
    private static let nxKeyTypeFast: Int = 19
    private static let nxKeyTypeRewind: Int = 20
    private static let keyboardMediaKeyTypes: Set<Int> = [
        nxKeyTypePlay,
        nxKeyTypeNext,
        nxKeyTypePrevious,
        nxKeyTypeFast,
        nxKeyTypeRewind
    ]

    private let state: AppState
    private let onTogglePressed: () -> Void
    private let onAirPodsTogglePressed: () -> Void
    private let onAirPodsSubmitPressed: () -> Void
    private let onHoldPressed: () -> Void
    private let onHoldReleased: () -> Void
    private let isRecording: () -> Bool
    private var hidManager: IOHIDManager?
    private var inputReportRegistrations: [InputReportRegistration] = []
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
    private var playPauseElement: IOHIDElement?
    private var playPauseReleasePollTimer: Timer?
    private var lastInputReportPlayPauseValue: UInt8 = 0
    private var longPressActive = false
    private var localMediaKeyMonitors: [Any] = []
    private var lastKeyboardMediaKeyAt: Date?
    private var airPodsAvailabilityTimer: Timer?
    private var lastAirPodsAvailability: Bool?

    private static func appendHeadsetDebugLog(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-headset.log")
    }

    private static func appendAirPodsDebugLog(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-airpods-remote.log")
    }

    init(
        state: AppState,
        onTogglePressed: @escaping () -> Void,
        onAirPodsTogglePressed: @escaping () -> Void,
        onAirPodsSubmitPressed: @escaping () -> Void,
        onHoldPressed: @escaping () -> Void,
        onHoldReleased: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.state = state
        self.onTogglePressed = onTogglePressed
        self.onAirPodsTogglePressed = onAirPodsTogglePressed
        self.onAirPodsSubmitPressed = onAirPodsSubmitPressed
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
        Self.appendHeadsetDebugLog("controls enabled=\(enabled)")
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
        syncAirPodsAvailabilityTimer()
        syncRemoteCommandProbe()
        if persist {
            state.statusText = enabled ? "Experimental AirPods enabled" : "Experimental AirPods disabled"
        }
    }

    func start() {
        guard controlsEnabled else { return }
        Self.appendHeadsetDebugLog("controls start")
        installHIDControl()
        syncAirPodsAvailabilityTimer()
        syncRemoteCommandProbe()
    }

    func stop() {
        cancelPendingLongPress()
        stopPlayPauseReleasePolling()
        stopAirPodsAvailabilityTimer()
        removeRemoteCommandProbe()
        removeHIDControl()
    }

    private func installHIDControl() {
        guard hidManager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer,
                kIOHIDDeviceUsageKey as String: kHIDUsage_Csmr_ConsumerControl,
                kIOHIDProductKey as String: "Headset",
                kIOHIDTransportKey as String: "Audio"
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let manager = Unmanaged<HeadsetProbeManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleHIDValue(value)
        }, context)

        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, type, reportID, report, reportLength in
            guard let context else { return }
            let manager = Unmanaged<HeadsetProbeManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleHIDInputReport(
                result: result,
                sender: sender,
                type: type,
                reportID: reportID,
                report: report,
                reportLength: reportLength
            )
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        var result = IOHIDManagerOpen(manager, openOptions)
        Self.appendHeadsetDebugLog("hid open seize result=\(result)")
        if result != kIOReturnSuccess {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            Self.appendHeadsetDebugLog("hid open fallback result=\(result)")
        }
        logMatchedHIDDevices(manager)
        installInputReportCallbacks(manager)
        hidManager = manager
    }

    private func logMatchedHIDDevices(_ manager: IOHIDManager) {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            Self.appendHeadsetDebugLog("hid devices=none")
            return
        }

        for device in devices {
            let product = Self.hidStringProperty(device, kIOHIDProductKey) ?? "unknown"
            let transport = Self.hidStringProperty(device, kIOHIDTransportKey) ?? "unknown"
            let builtIn = Self.isBuiltInHIDDevice(device)
            let usagePage = Self.hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
            let usage = Self.hidIntProperty(device, kIOHIDPrimaryUsageKey)
            Self.appendHeadsetDebugLog("hid device product=\(product) transport=\(transport) builtIn=\(builtIn) usagePage=\(usagePage) usage=\(usage)")
        }
    }

    private func installInputReportCallbacks(_ manager: IOHIDManager) {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            Self.appendHeadsetDebugLog("hid report callbacks skipped reason=no-devices")
            return
        }

        for device in devices where Self.isWiredHeadsetHIDDevice(device) {
            let maxReportSize = max(1, Self.hidIntProperty(device, kIOHIDMaxInputReportSizeKey))
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReportSize)
            buffer.initialize(repeating: 0, count: maxReportSize)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, CFIndex(maxReportSize), { context, result, sender, type, reportID, report, reportLength in
                guard let context else { return }
                let manager = Unmanaged<HeadsetProbeManager>.fromOpaque(context).takeUnretainedValue()
                manager.handleHIDInputReport(
                    result: result,
                    sender: sender,
                    type: type,
                    reportID: reportID,
                    report: report,
                    reportLength: reportLength
                )
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            inputReportRegistrations.append(InputReportRegistration(device: device, buffer: buffer, length: CFIndex(maxReportSize), scheduled: true))
            let product = Self.hidStringProperty(device, kIOHIDProductKey) ?? "unknown"
            Self.appendHeadsetDebugLog("hid report callback installed product=\(product) maxReportSize=\(maxReportSize) scheduled=true")
        }
    }

    private func removeHIDControl() {
        guard let hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
        for registration in inputReportRegistrations {
            if registration.scheduled {
                IOHIDDeviceUnscheduleFromRunLoop(registration.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            }
            registration.buffer.deallocate()
        }
        inputReportRegistrations.removeAll()
    }

    private func syncRemoteCommandProbe() {
        if controlsEnabled && airPodsControlEnabled && isAirPodsInputConnected() {
            installRemoteCommandProbe()
        } else {
            removeRemoteCommandProbe()
        }
    }

    private func installRemoteCommandProbe() {
        guard remoteCommandTargets.isEmpty else { return }
        guard isAirPodsInputConnected() else {
            publishAirPodsAvailabilityIfChanged(false)
            return
        }
        if airPodsControlEnabled {
            startSilentAirPodsProbeAudio()
            publishAirPodsProbeNowPlaying()
        }
        installLocalMediaKeySuppression()
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
        Self.appendHeadsetDebugLog("remote commands installed count=\(remoteCommandTargets.count)")
        startAirPodsNowPlayingTimer()
    }

    private func syncAirPodsAvailabilityTimer() {
        if controlsEnabled && airPodsControlEnabled {
            startAirPodsAvailabilityTimer()
        } else {
            stopAirPodsAvailabilityTimer()
        }
    }

    private func startAirPodsAvailabilityTimer() {
        guard airPodsAvailabilityTimer == nil else { return }
        publishAirPodsAvailabilityIfChanged(isAirPodsInputConnected())
        airPodsAvailabilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.publishAirPodsAvailabilityIfChanged(self.isAirPodsInputConnected())
            self.syncRemoteCommandProbe()
        }
    }

    private func stopAirPodsAvailabilityTimer() {
        airPodsAvailabilityTimer?.invalidate()
        airPodsAvailabilityTimer = nil
        lastAirPodsAvailability = nil
    }

    private func publishAirPodsAvailabilityIfChanged(_ connected: Bool) {
        guard lastAirPodsAvailability != connected else { return }
        lastAirPodsAvailability = connected
        let name = DefaultAudioInputOverride.airPodsInputDeviceID().flatMap { DefaultAudioInputOverride.audioDeviceName($0) } ?? "none"
        Self.appendAirPodsDebugLog("availability connected=\(connected) input=\(name)")
    }

    private func isAirPodsInputConnected() -> Bool {
        DefaultAudioInputOverride.airPodsInputDeviceID() != nil
    }

    private func removeRemoteCommandProbe() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
            target.command.isEnabled = false
        }
        remoteCommandTargets.removeAll()
        removeLocalMediaKeySuppression()
        stopAirPodsNowPlayingTimer()
        stopSilentAirPodsProbeAudio()
        clearAirPodsProbeNowPlaying()
    }

    private func logRemoteCommand(_ label: String, event: MPRemoteCommandEvent) {
        Self.appendAirPodsDebugLog("mp label=\(label) recording=\(isRecording())")
        refreshAirPodsRemoteTarget()
        guard !shouldSuppressRemoteCommandAfterKeyboardMediaKey(label) else {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=keyboard-media-key")
            return
        }
        handleAirPodsRemoteCommand(label)
    }

    private func installLocalMediaKeySuppression() {
        guard localMediaKeyMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.recordKeyboardMediaKeyIfNeeded(event)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: handler) {
            localMediaKeyMonitors.append(monitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { [weak self] event in
            self?.recordKeyboardMediaKeyIfNeeded(event)
            return event
        }) {
            localMediaKeyMonitors.append(localMonitor)
        }
    }

    private func removeLocalMediaKeySuppression() {
        localMediaKeyMonitors.forEach(NSEvent.removeMonitor)
        localMediaKeyMonitors.removeAll()
        lastKeyboardMediaKeyAt = nil
    }

    private func recordKeyboardMediaKeyIfNeeded(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let keyCode = (event.data1 & 0xffff0000) >> 16
        let keyState = (event.data1 & 0x0000ff00) >> 8
        guard keyState == 0x0a, Self.keyboardMediaKeyTypes.contains(keyCode) else { return }
        lastKeyboardMediaKeyAt = Date()
        Self.appendAirPodsDebugLog("keyboard media key observed keyCode=\(keyCode)")
    }

    private func shouldSuppressRemoteCommandAfterKeyboardMediaKey(_ label: String) -> Bool {
        guard label.hasPrefix("remote "), let lastKeyboardMediaKeyAt else { return false }
        return Date().timeIntervalSince(lastKeyboardMediaKeyAt) <= Self.keyboardMediaKeySuppressWindow
    }

    private func handleAirPodsRemoteCommand(_ label: String) {
        guard airPodsControlEnabled else {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=disabled")
            return
        }
        let recording = isRecording()
        let isRecordCommand = label == "remote nextTrack" || label == "hid nextTrack"
        let isSubmitCommand = label == "remote play" || label == "remote pause" || label == "remote togglePlayPause" || label == "remote stop"
        guard isRecordCommand || isSubmitCommand else {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=unsupported-command recording=\(recording)")
            return
        }
        if let lastAirPodsToggleAt, Date().timeIntervalSince(lastAirPodsToggleAt) < 0.45 {
            Self.appendAirPodsDebugLog("ignored label=\(label) reason=debounce")
            return
        }
        lastAirPodsToggleAt = Date()

        if isSubmitCommand {
            if recording {
                Self.appendAirPodsDebugLog("ignored label=\(label) reason=submit-while-recording")
                return
            }
            Self.appendAirPodsDebugLog("submit label=\(label)")
            DispatchQueue.main.async { [onAirPodsSubmitPressed] in
                onAirPodsSubmitPressed()
            }
        } else {
            Self.appendAirPodsDebugLog("record label=\(label) recordingBefore=\(recording)")
            DispatchQueue.main.async { [onAirPodsTogglePressed] in
                onAirPodsTogglePressed()
            }
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
        guard isAirPodsInputConnected() else {
            publishAirPodsAvailabilityIfChanged(false)
            removeRemoteCommandProbe()
            return
        }
        ensureSilentAirPodsProbeAudio()
        publishAirPodsProbeNowPlaying()
    }

    private func ensureSilentAirPodsProbeAudio() {
        guard airPodsControlEnabled else { return }
        guard isAirPodsInputConnected() else { return }
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
        guard isAirPodsInputConnected() else {
            publishAirPodsAvailabilityIfChanged(false)
            return
        }
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

    private func handleHIDInputReport(
        result: IOReturn,
        sender: UnsafeMutableRawPointer?,
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess else {
            Self.appendHeadsetDebugLog("hid report result=\(result) reportID=\(reportID) length=\(reportLength)")
            return
        }
        guard let report, reportLength > 0 else {
            Self.appendHeadsetDebugLog("hid report empty reportID=\(reportID) length=\(reportLength)")
            return
        }

        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
        let firstByte = bytes.first ?? 0
        let playPauseValue = firstByte & 0x01
        let hexBytes = bytes.map { String(format: "%02x", $0) }.joined(separator: "")
        Self.appendHeadsetDebugLog("hid report type=\(type.rawValue) reportID=\(reportID) length=\(reportLength) bytes=\(hexBytes) playPause=\(playPauseValue)")

        guard playPauseValue != lastInputReportPlayPauseValue else {
            Self.appendHeadsetDebugLog("hid report ignored reason=playpause-unchanged value=\(playPauseValue)")
            return
        }

        lastInputReportPlayPauseValue = playPauseValue
        handlePlayPauseValue(CFIndex(playPauseValue))
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard !Self.isBuiltInHIDDevice(device) else {
            return
        }
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let product = Self.hidStringProperty(device, kIOHIDProductKey) ?? "unknown"
        let transport = Self.hidStringProperty(device, kIOHIDTransportKey) ?? "unknown"
        Self.appendHeadsetDebugLog("hid value product=\(product) transport=\(transport) usagePage=\(usagePage) usage=\(usage) value=\(intValue) pressStarted=\(headsetPressStartedAt != nil) longActive=\(longPressActive) recording=\(isRecording())")

        if Self.isWiredHeadsetHIDDevice(device), usagePage == kHIDPage_Consumer {
            if usage == Self.nextTrackUsage, intValue != 0, airPodsControlEnabled {
                Self.appendAirPodsDebugLog("hid usage=nextTrack recording=\(isRecording())")
                handleAirPodsRemoteCommand("hid nextTrack")
                return
            }
            guard usage == Self.playPauseUsage else {
                Self.appendHeadsetDebugLog("hid ignored reason=wired-headset-non-playpause usage=\(usage) value=\(intValue)")
                return
            }
            playPauseElement = element
            handlePlayPauseValue(intValue)
            return
        }

        Self.appendHeadsetDebugLog("hid ignored reason=not-wired-headset product=\(product) transport=\(transport) usagePage=\(usagePage) usage=\(usage)")
    }

    private static func isBuiltInHIDDevice(_ device: IOHIDDevice) -> Bool {
        if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) {
            if CFGetTypeID(builtIn) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((builtIn as! CFBoolean))
            }
            if let number = builtIn as? NSNumber {
                return number.boolValue
            }
        }
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
        return product.contains("internal keyboard")
            || product.contains("apple internal")
            || product.contains("applem68buttons")
    }

    private static func isWiredHeadsetHIDDevice(_ device: IOHIDDevice) -> Bool {
        let product = (hidStringProperty(device, kIOHIDProductKey) ?? "").lowercased()
        let transport = (hidStringProperty(device, kIOHIDTransportKey) ?? "").lowercased()
        return product.contains("headset") || transport == "audio"
    }

    private static func hidStringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func hidIntProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return -1
        }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as! NSNumber).intValue
        }
        return -1
    }

    private func handlePlayPauseValue(_ value: CFIndex) {
        if value != 0 {
            if headsetPressStartedAt != nil {
                if longPressActive && mode == .longPressHold {
                    Self.appendHeadsetDebugLog("hid nonzero-after-active treated-as-release")
                    stopActiveHold()
                } else {
                    Self.appendHeadsetDebugLog("hid repeat-down ignored")
                }
                return
            }

            Self.appendHeadsetDebugLog("hid press-start schedule-long threshold=\(Self.longPressThreshold)")
            headsetPressStartedAt = Date()
            longPressActive = false
            longPressWorkItem?.cancel()
            startPlayPauseReleasePolling()
            let workItem = DispatchWorkItem { [weak self] in
                self?.activateLongPressIfStillDown()
            }
            longPressWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressThreshold, execute: workItem)
        } else {
            if longPressActive && mode == .longPressHold {
                Self.appendHeadsetDebugLog("hid zero-release stop-active-hold")
                stopActiveHold()
            } else if mode == .longPressHold && pressDurationHasReachedLongThreshold() {
                Self.appendHeadsetDebugLog("hid zero-release after-threshold activate-and-stop")
                activateLongPressIfStillDown()
                stopActiveHold()
            } else {
                Self.appendHeadsetDebugLog("hid zero-release cancel-before-active")
                cancelPendingLongPress()
            }
        }
    }

    private func activateLongPressIfStillDown() {
        guard headsetPressStartedAt != nil, mode.controlsWiredRecording, !longPressActive else { return }
        longPressActive = true
        Self.appendHeadsetDebugLog("hid long-press-activated mode=\(mode)")

        switch mode {
        case .longPressHold:
            onHoldPressed()
        case .longPressToggle:
            onTogglePressed()
        }
    }

    private func stopActiveHold() {
        Self.appendHeadsetDebugLog("hid stop-active-hold dispatch-release")
        cancelPendingLongPress()
        DispatchQueue.main.async { [onHoldReleased] in
            onHoldReleased()
        }
    }

    private func cancelPendingLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        headsetPressStartedAt = nil
        longPressActive = false
        stopPlayPauseReleasePolling()
    }

    private func startPlayPauseReleasePolling() {
        Self.appendHeadsetDebugLog("hid poll disabled reason=raw-report-callback")
    }

    private func stopPlayPauseReleasePolling() {
        playPauseReleasePollTimer?.invalidate()
        playPauseReleasePollTimer = nil
    }

    private func pollPlayPauseRelease() {
        Self.appendHeadsetDebugLog("hid poll ignored reason=disabled")
    }

    private func pressDurationHasReachedLongThreshold() -> Bool {
        guard let headsetPressStartedAt else { return false }
        return Date().timeIntervalSince(headsetPressStartedAt) >= Self.longPressThreshold
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
    private var nextSyntheticRecordingData: Data?
    private var activeSyntheticRecordingData: Data?
    var onAudioLevel: ((Float) -> Void)?

    private static func appendRecorderDebugLog(_ message: String) {
        DebugLog.append(message, to: "/tmp/wire-recorder.log")
    }

    var isRecording: Bool { engine?.isRunning ?? false }
    var hasActiveRecording: Bool {
        activeSyntheticRecordingData != nil || (engine != nil && tempURL != nil) || audioQueue != nil
    }

    func useSyntheticRecordingData(_ data: Data) {
        nextSyntheticRecordingData = data
    }

    /// Start recording to a temporary WAV file
    func start(inputDeviceID: AudioDeviceID? = nil) throws {
        guard !hasActiveRecording else { return }
        if let nextSyntheticRecordingData {
            activeSyntheticRecordingData = nextSyntheticRecordingData
            self.nextSyntheticRecordingData = nil
            Self.appendRecorderDebugLog("start-synthetic bytes=\(nextSyntheticRecordingData.count)")
            return
        }
        if inputDeviceID != nil {
            try startSpecificMicCapture(inputDeviceID: inputDeviceID!)
            return
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        Self.appendRecorderDebugLog("start-default deviceName=\(Self.defaultInputDeviceName()) sampleRate=\(format.sampleRate) channels=\(format.channelCount)")

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

    private static func defaultInputDeviceName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return "unknown"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, &name) == noErr,
              let name else {
            return "device-\(deviceID)"
        }
        return name.takeUnretainedValue() as String
    }

    private func startSpecificMicCapture(inputDeviceID: AudioDeviceID) throws {
        guard let deviceUID = DefaultAudioInputOverride.audioDeviceUID(inputDeviceID) else {
            throw AppError.transcriptionFailed("Could not read selected microphone device UID")
        }
        let deviceName = DefaultAudioInputOverride.audioDeviceName(inputDeviceID) ?? "device-\(inputDeviceID)"
        let sampleRate = max(16_000, DefaultAudioInputOverride.nominalSampleRate(inputDeviceID) ?? 16_000)
        Self.appendRecorderDebugLog("start-specific-input deviceName=\(deviceName) uid=\(deviceUID) sampleRate=\(sampleRate)")
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
            publishAudioLevel(buffer: buffer)
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

    private func publishAudioLevel(buffer: AudioQueueBufferRef) {
        guard audioQueueFormat.mFormatID == kAudioFormatLinearPCM,
              audioQueueFormat.mBitsPerChannel == 16,
              buffer.pointee.mAudioDataByteSize >= UInt32(MemoryLayout<Int16>.size) else {
            return
        }

        let sampleCount = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        var sumSquares: Double = 0
        for index in 0..<sampleCount {
            let sample = Double(samples[index])
            sumSquares += sample * sample
        }
        let rms = Float(sqrt(sumSquares / Double(sampleCount)))
        onAudioLevel?(rms)
    }

    /// Stop recording and return the audio data
    private func stopAndTranscribe() -> Data? {
        if let activeSyntheticRecordingData {
            self.activeSyntheticRecordingData = nil
            return activeSyntheticRecordingData
        }
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
        process.arguments = ["-f", "WAVE", "-d", "LEI16", "-c", "1", inputURL.path, outputURL.path]

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
    private static let sessionURLString = "https://chatgpt.com"
    private static let maximumPrepareAttempts = 6
    private static let prepareRetryDelays: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        15_000_000_000
    ]

    private var webView: WKWebView?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var prepareTask: Task<Void, Error>?

    private var authToken: String = ""
    private var accountID: String = ""
    private var transcriptionContinuation: CheckedContinuation<String, Error>?

    /// Read token from ~/.codex/auth.json and prepare the WKWebView session.
    func prepare() async throws {
        if isReady, webView != nil {
            return
        }
        if let prepareTask {
            try await prepareTask.value
            return
        }

        let task = Task { @MainActor in
            try await prepareWithRetries()
        }
        prepareTask = task
        do {
            try await task.value
            prepareTask = nil
        } catch {
            prepareTask = nil
            throw error
        }
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

    private func prepareWithRetries() async throws {
        try readAuthToken()

        var lastError: Error = AppError.sessionNotReady
        for attempt in 0..<Self.maximumPrepareAttempts {
            do {
                try await setupWebView()
                return
            } catch {
                lastError = error
                cleanupWebView()
                if attempt < Self.prepareRetryDelays.count {
                    try await Task.sleep(nanoseconds: Self.prepareRetryDelays[attempt])
                }
            }
        }
        throw lastError
    }

    private func setupWebView() async throws {
        isReady = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation

            let config = WKWebViewConfiguration()
            let userContentController = WKUserContentController()
            userContentController.add(self, name: "transcribeResult")
            config.userContentController = userContentController
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Codex Desktop/26.513.20950 (Macintosh; Intel Mac OS X)"
            self.webView = webView

            // Load chatgpt.com to establish Cloudflare/session cookies before the API call.
            let request = URLRequest(url: URL(string: Self.sessionURLString)!)
            webView.load(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak webView] in
                guard let self, !self.isReady, self.webView === webView else { return }
                self.finishPreparing(.failure(AppError.transcriptionFailed("Timed out loading ChatGPT session")))
            }
        }
    }

    private func finishPreparing(_ result: Result<Void, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        switch result {
        case .success:
            isReady = true
            continuation.resume()
        case .failure(let error):
            isReady = false
            continuation.resume(throwing: error)
        }
    }

    private func cleanupWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        isReady = false
        readyContinuation = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView,
              webView.url?.host?.hasSuffix("chatgpt.com") == true else {
            return
        }
        finishPreparing(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finishPreparing(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finishPreparing(.failure(error))
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
        do {
            return try await transcribePrepared(audioData: audioData)
        } catch {
            if isAuthTokenFailure(error) {
                try readAuthToken()
                return try await transcribePrepared(audioData: audioData)
            }
            guard isWebViewSessionFailure(error) else {
                throw error
            }
            cleanupWebView()
            try await prepare()
            return try await transcribePrepared(audioData: audioData)
        }
    }

    private func transcribePrepared(audioData: Data) async throws -> String {
        if !isReady || webView == nil {
            try await prepare()
        }
        guard let webView = webView else {
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
                    self.cleanupWebView()
                    finish(.failure(AppError.transcriptionFailed(error.localizedDescription)))
                }
            }
        }
    }

    private func isWebViewSessionFailure(_ error: Error) -> Bool {
        guard case AppError.transcriptionFailed(let message) = error else {
            return false
        }
        return message == "Load failed"
            || message.localizedCaseInsensitiveContains("webview")
            || message.localizedCaseInsensitiveContains("could not connect to the server")
            || message.localizedCaseInsensitiveContains("the internet connection appears to be offline")
            || message.localizedCaseInsensitiveContains("network connection was lost")
    }

    private func isAuthTokenFailure(_ error: Error) -> Bool {
        guard case AppError.transcriptionFailed(let message) = error else {
            return false
        }
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("token_expired")
            || lowercasedMessage.contains("token expired")
            || lowercasedMessage.contains("authentication token is expired")
            || ((message.contains("HTTP 400")
                    || message.contains("HTTP 401")
                    || message.contains("HTTP 403"))
                && (lowercasedMessage.contains("token")
                    || lowercasedMessage.contains("auth")
                    || lowercasedMessage.contains("unauthorized")
                    || lowercasedMessage.contains("forbidden")))
    }


    private static let cleanupInstructions = """
        Clean up dictation transcripts. Fix likely speech recognition mistakes, punctuation, capitalization, \
        and formatting. Remove filler words and disfluencies when they do not add meaning. When the user \
        clearly self-corrects or backtracks, keep the corrected intent. Preserve the user's meaning, wording, \
        and flow unless a small cleanup makes the transcript more coherent. Do not answer the user or add \
        new content. Return only the cleaned transcript.
        """

    func cleanup(text: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        if !isReady || webView == nil {
            try await prepare()
        }
        guard let webView = webView else {
            throw AppError.sessionNotReady
        }

        let rawText = text
        let token = authToken
        let account = accountID
        let instructions = Self.cleanupInstructions

        let functionBody = """
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 60000);
        try {
            const response = await fetch('https://chatgpt.com/backend-api/codex/responses', {
                method: 'POST',
                headers: {
                    'Authorization': 'Bearer ' + authToken,
                    'ChatGPT-Account-Id': accountID,
                    'Content-Type': 'application/json',
                    'originator': 'codex_desktop'
                },
                body: JSON.stringify({
                    model: 'gpt-5.5',
                    input: [{ role: 'user', content: rawText }],
                    instructions: instructions,
                    store: false,
                    stream: true
                }),
                signal: controller.signal
            });
            clearTimeout(timeout);

            if (!response.ok) {
                const errorText = await response.text();
                return JSON.stringify({ success: false, error: 'HTTP ' + response.status + ': ' + errorText.substring(0, 500) });
            }

            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let buffer = '';
            let finalText = '';
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                buffer += decoder.decode(value, { stream: true });
                const lines = buffer.split('\\n');
                buffer = lines.pop();
                for (const line of lines) {
                    if (!line.startsWith('data: ')) continue;
                    const data = line.slice(6);
                    if (data === '[DONE]') continue;
                    try {
                        const event = JSON.parse(data);
                        if (event.type === 'response.output_text.done') {
                            finalText = event.text || '';
                        }
                    } catch (e) {}
                }
            }
            if (finalText) {
                return JSON.stringify({ success: true, text: finalText });
            }
            return JSON.stringify({ success: false, error: 'No output text in response' });
        } catch (e) {
            clearTimeout(timeout);
            return JSON.stringify({ success: false, error: e && e.name === 'AbortError' ? 'Cleanup request timed out' : (e.message || String(e)) });
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 70) {
                finish(.failure(AppError.transcriptionFailed("Timed out waiting for cleanup response")))
            }

            webView.callAsyncJavaScript(
                functionBody,
                arguments: [
                    "rawText": rawText,
                    "authToken": token,
                    "accountID": account,
                    "instructions": instructions
                ],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let jsonString = value as? String,
                          let jsonData = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                        finish(.failure(AppError.transcriptionFailed("Invalid JavaScript result from cleanup")))
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
        cleanupWebView()
        prepareTask?.cancel()
        prepareTask = nil
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


// MARK: - Menu Bar Popover

final class MenuBarPopoverViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 286
    }

    private let state: AppState
    private let statusLabel = NSTextField(labelWithString: "")
    private let transcriptLabel = NSTextField(labelWithString: "No recent transcription")
    private let copyLatestButton = NSButton(title: "", target: nil, action: nil)
    private let retryLastButton = NSButton(title: "", target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()
    private let openSettingsButton = NSButton(title: "Open Settings…", target: nil, action: nil)
    private let quitButton = HoverMenuButton(title: "", target: nil, action: nil)

    var onOpenSettings: (() -> Void)?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 0))
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        view = visual
        buildUI()
        refresh()
    }

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 9, right: 14)

        let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) ?? NSImage())
        mic.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        mic.contentTintColor = .controlAccentColor
        mic.widthAnchor.constraint(equalToConstant: 14).isActive = true
        mic.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let title = NSTextField(labelWithString: "wire")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        let titleRow = NSStackView(views: [mic, title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 5
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
        root.addArrangedSubview(header)
        root.addArrangedSubview(WireUI.divider())

        root.addArrangedSubview(WireUI.popoverSectionLabel("Latest"))

        transcriptLabel.font = .systemFont(ofSize: 12)
        transcriptLabel.textColor = .secondaryLabelColor
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.maximumNumberOfLines = 4
        transcriptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(copyLatestButton, symbol: "doc.on.doc", tip: "Copy latest transcription", action: #selector(copyLatest))
        configureIconButton(retryLastButton, symbol: "arrow.clockwise", tip: "Retry saved recording", action: #selector(retryLastRecording))

        let latestRow = NSStackView()
        latestRow.orientation = .horizontal
        latestRow.alignment = .top
        latestRow.spacing = 8
        latestRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        latestRow.addArrangedSubview(transcriptLabel)
        latestRow.addArrangedSubview(retryLastButton)
        latestRow.addArrangedSubview(copyLatestButton)
        root.addArrangedSubview(latestRow)

        root.addArrangedSubview(WireUI.divider())

        openSettingsButton.bezelStyle = .recessed
        openSettingsButton.controlSize = .regular
        openSettingsButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettingsPressed)

        let settingsRow = NSStackView(views: [openSettingsButton])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.distribution = .fill
        settingsRow.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 5, right: 14)
        root.addArrangedSubview(settingsRow)

        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.target = self
        quitButton.action = #selector(quitWire)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let quitContent = NSStackView()
        quitContent.orientation = .horizontal
        quitContent.alignment = .centerY
        quitContent.spacing = 7
        quitContent.translatesAutoresizingMaskIntoConstraints = false
        let quitIcon = NSImageView(image: NSImage(systemSymbolName: "power", accessibilityDescription: nil) ?? NSImage())
        quitIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        quitIcon.contentTintColor = .systemRed
        quitIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let quitLabel = NSTextField(labelWithString: "Quit")
        quitLabel.font = .systemFont(ofSize: 12)
        quitLabel.textColor = .systemRed
        quitContent.addArrangedSubview(quitIcon)
        quitContent.addArrangedSubview(quitLabel)
        quitButton.addSubview(quitContent)

        let quitRow = NSView()
        quitRow.translatesAutoresizingMaskIntoConstraints = false
        quitRow.addSubview(quitButton)
        NSLayoutConstraint.activate([
            quitRow.heightAnchor.constraint(equalToConstant: 36),
            quitButton.centerXAnchor.constraint(equalTo: quitRow.centerXAnchor),
            quitButton.centerYAnchor.constraint(equalTo: quitRow.centerYAnchor),
            quitButton.widthAnchor.constraint(equalToConstant: 88),
            quitButton.heightAnchor.constraint(equalToConstant: 28),
            quitContent.centerXAnchor.constraint(equalTo: quitButton.centerXAnchor),
            quitContent.centerYAnchor.constraint(equalTo: quitButton.centerYAnchor)
        ])
        root.addArrangedSubview(quitRow)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tip
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            image.isTemplate = true
            button.image = image
        }
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    func refresh() {
        guard isViewLoaded else { return }
        statusLabel.stringValue = state.statusText.isEmpty ? "Ready" : state.statusText

        switch state.transcriptionStage {
        case .transcribing:
            loadingIndicator.startAnimation(nil)
        default:
            if state.computerCommandRunning {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }
        }

        if state.computerCommandRunning {
            transcriptLabel.stringValue = "Running command…"
        } else if state.transcriptionStage == .transcribing {
            transcriptLabel.stringValue = "Transcribing…"
        } else if state.lastTranscription.isEmpty {
            transcriptLabel.stringValue = "No recent transcription"
        } else {
            transcriptLabel.stringValue = state.lastTranscription
        }

        copyLatestButton.isEnabled = !state.lastTranscription.isEmpty
        retryLastButton.isHidden = !state.hasRecoverableRecording
        retryLastButton.isEnabled = state.hasRecoverableRecording && !state.isBusy

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let width = Layout.width
        let height = max(196, view.fittingSize.height)
        preferredContentSize = NSSize(width: width, height: height)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
    }

    @objc private func copyLatest() {
        guard !state.lastTranscription.isEmpty else { return }
        if Clipboard.copy(state.lastTranscription) {
            state.statusText = "Copied latest transcription"
        } else {
            state.statusText = "Copy failed"
        }
        refresh()
    }

    @objc private func retryLastRecording() {
        (NSApp.delegate as? AppDelegate)?.retryLastRecordingObjc()
    }

    @objc private func quitWire() {
        NSApp.terminate(nil)
    }

    @objc private func openSettingsPressed() {
        onOpenSettings?()
    }
}

// MARK: - Settings UI Helpers

private enum WireUI {
    enum Metrics {
        static let settingsInset = NSEdgeInsets(top: 18, left: 28, bottom: 16, right: 28)
        static let groupSpacing: CGFloat = 22
        static let rowHeight: CGFloat = 34
        static let rowInsetX: CGFloat = 0
        static let iconSize: CGFloat = 16
        static let iconTitleGap: CGFloat = 10
        static let separatorInset: CGFloat = 0
    }

    static func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    static func popoverSectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [label])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
        return row
    }

    static func settingsGroup(title: String, rows: [NSView]) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 7
        column.alignment = .width
        column.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = .secondaryLabelColor
        heading.translatesAutoresizingMaskIntoConstraints = false
        let headingRow = NSView()
        headingRow.translatesAutoresizingMaskIntoConstraints = false
        headingRow.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: headingRow.trailingAnchor),
            heading.topAnchor.constraint(equalTo: headingRow.topAnchor),
            heading.bottomAnchor.constraint(equalTo: headingRow.bottomAnchor)
        ])
        column.addArrangedSubview(headingRow)

        let card = NSStackView()
        card.orientation = .vertical
        card.spacing = 6
        card.alignment = .width
        card.detachesHiddenViews = true
        card.translatesAutoresizingMaskIntoConstraints = false

        for row in rows {
            card.addArrangedSubview(row)
        }
        column.addArrangedSubview(card)
        return column
    }

    static func insetRowSeparator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.separatorInset),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    static func menuRow(symbol: String, title: String, trailing: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        container.addSubview(icon)
        container.addSubview(label)
        container.addSubview(trailing)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.rowInsetX),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.iconTitleGap),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),

            trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.rowInsetX),
            trailing.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    static func fullWidthFieldRow(symbol: String, title: String, field: NSView) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 7
        column.alignment = .width
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.rowInsetX, bottom: 6, right: Metrics.rowInsetX)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = Metrics.iconTitleGap

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .tertiaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: Metrics.iconSize).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        titleRow.addArrangedSubview(icon)
        titleRow.addArrangedSubview(label)

        field.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(titleRow)
        column.addArrangedSubview(field)
        return column
    }

    static func trailingGroup(_ views: [NSView]) -> NSView {
        let group = NSStackView()
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            group.addArrangedSubview(view)
        }
        return group
    }

    static func configureSwitch(_ control: NSSwitch, target: AnyObject?, action: Selector) {
        control.target = target
        control.action = action
        control.controlSize = .small
    }

    static func configureInfoButton(_ button: NSButton, target: AnyObject?, action: Selector, accessibilityDescription: String) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.toolTip = accessibilityDescription
        if let infoImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: accessibilityDescription) {
            infoImage.isTemplate = true
            button.image = infoImage
        }
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
}


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

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings View Controller

final class SettingsViewController: NSViewController, NSTextFieldDelegate, NSToolbarDelegate {
    private enum Layout {
        static let minWidth: CGFloat = 480
        static let minHeight: CGFloat = 280
    }

    private enum SettingsPane: Int, CaseIterable {
        case general
        case headset
        case computer

        var title: String {
            switch self {
            case .general: return "General"
            case .headset: return "Headset"
            case .computer: return "Computer"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .headset: return "headphones"
            case .computer: return "desktopcomputer"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("wire.settings.\(title.lowercased())")
        }

        var contentHeight: CGFloat {
            switch self {
            case .general: return 330
            case .headset: return 360
            case .computer: return 370
            }
        }
    }

    private static let toolbarIdentifier = NSToolbar.Identifier("wire.settings.toolbar")

    private let state: AppState
    private let hotKeyManager: HotKeyManager
    private let headsetProbeManager: HeadsetProbeManager
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()
    private let pageHost = NSStackView()
    private let footerStatusLabel = NSTextField(labelWithString: "")
    private let generalStack = NSStackView()
    private let headsetStack = NSStackView()
    private let computerStack = NSStackView()
    private let toggleShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let holdShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let headsetModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headsetControlsSwitch = NSSwitch()
    private let sendEnterAfterPasteSwitch = NSSwitch()
    private let cleanupSwitch = NSSwitch()
    private let backgroundPasteSwitch = NSSwitch()
    private let cleanupInfoButton = NSButton(title: "", target: nil, action: nil)
    private let backgroundPasteInfoButton = NSButton(title: "", target: nil, action: nil)
    private let airPodsControlSwitch = NSSwitch()
    private let headsetControlsInfoButton = NSButton(title: "", target: nil, action: nil)
    private let sendEnterInfoButton = NSButton(title: "", target: nil, action: nil)
    private let airPodsInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerControlsSwitch = NSSwitch()
    private let computerInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerCustomHarnessSwitch = NSSwitch()
    private let computerHarnessInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerAutoEnableSwitch = NSSwitch()
    private let computerAutoEnableInfoButton = NSButton(title: "", target: nil, action: nil)
    private let computerAutoEnableField = NSTextField(string: "")
    private let computerAutoDisableField = NSTextField(string: "")
    private let computerHarnessField = NSTextField(string: "")
    private var headsetSettingsRows: [NSView] = []
    private var computerModeRows: [NSView] = []
    private var computerAutoEnableRows: [NSView] = []
    private var computerHarnessRows: [NSView] = []
    private var headsetCollapsedSpacer: NSView?
    private var backgroundPasteInfoPopover: NSPopover?
    private var settingsInfoPopover: NSPopover?
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
    private var computerAutoDisableSaveWorkItem: DispatchWorkItem?
    private var computerHarnessSaveWorkItem: DispatchWorkItem?
    private var selectedPane: SettingsPane = .general

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: SettingsPane.general.contentHeight))
        view.wantsLayer = true
        buildUI()
        refresh()
    }

    private func buildUI() {
        footerStatusLabel.font = .systemFont(ofSize: 11)
        footerStatusLabel.textColor = .secondaryLabelColor
        footerStatusLabel.lineBreakMode = .byTruncatingTail
        footerStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        pageHost.orientation = .vertical
        pageHost.alignment = .width
        pageHost.spacing = 0
        pageHost.detachesHiddenViews = true
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(pageHost)

        configureTabStack(generalStack)
        configureTabStack(headsetStack)
        configureTabStack(computerStack)
        buildGeneralTab()
        buildHeadsetTab()
        buildComputerTab()
        selectSettingsPane(.general)

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minWidth),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minHeight),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            pageHost.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: documentView.topAnchor),
            pageHost.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -12)
        ])
    }

    private func configureTabStack(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.spacing = WireUI.Metrics.groupSpacing
        stack.alignment = .width
        stack.edgeInsets = WireUI.Metrics.settingsInset
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = selectedPane.toolbarIdentifier
        return toolbar
    }

    private func selectSettingsPane(_ pane: SettingsPane) {
        selectedPane = pane
        view.window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        while let subview = pageHost.arrangedSubviews.first {
            pageHost.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let activeStack: NSStackView
        switch pane {
        case .general: activeStack = generalStack
        case .headset: activeStack = headsetStack
        case .computer: activeStack = computerStack
        }
        pageHost.addArrangedSubview(activeStack)
        resizeWindowForSelectedPane()
    }

    func resizeWindowForSelectedPane() {
        guard let window = view.window else { return }
        let width = max(window.contentView?.bounds.width ?? 560, Layout.minWidth)
        window.setContentSize(NSSize(width: width, height: selectedPane.contentHeight))
    }

    @objc private func settingsToolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else {
            return
        }
        selectSettingsPane(pane)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { $0.toolbarIdentifier == itemIdentifier }) else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.target = self
        item.action = #selector(settingsToolbarItemSelected(_:))
        if let image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title) {
            image.isTemplate = true
            item.image = image
        }
        return item
    }

    private func buildGeneralTab() {
        configureShortcutButton(holdShortcutButton)
        configureShortcutButton(toggleShortcutButton)
        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(captureHoldShortcut)
        toggleShortcutButton.target = self
        toggleShortcutButton.action = #selector(captureToggleShortcut)
        WireUI.configureSwitch(cleanupSwitch, target: self, action: #selector(toggleCleanup))
        WireUI.configureSwitch(backgroundPasteSwitch, target: self, action: #selector(toggleBackgroundPaste))
        WireUI.configureInfoButton(cleanupInfoButton, target: self, action: #selector(showCleanupInfo), accessibilityDescription: "Clean up transcript details")
        WireUI.configureInfoButton(backgroundPasteInfoButton, target: self, action: #selector(showBackgroundPasteInfo), accessibilityDescription: "Paste to source app details")

        let shortcutRows = [
            WireUI.menuRow(symbol: "keyboard.badge.ellipsis", title: "Hold shortcut", trailing: holdShortcutButton),
            WireUI.menuRow(symbol: "keyboard", title: "Toggle shortcut", trailing: toggleShortcutButton)
        ]
        generalStack.addArrangedSubview(WireUI.settingsGroup(title: "Shortcuts", rows: shortcutRows))

        let transcriptionRows = [
            WireUI.menuRow(symbol: "text.badge.checkmark", title: "Clean up transcript", trailing: WireUI.trailingGroup([cleanupInfoButton, cleanupSwitch])),
            WireUI.menuRow(symbol: "arrowshape.turn.up.left", title: "Paste to source app", trailing: WireUI.trailingGroup([backgroundPasteInfoButton, backgroundPasteSwitch]))
        ]
        generalStack.addArrangedSubview(WireUI.settingsGroup(title: "Transcription", rows: transcriptionRows))
    }

    private func configureShortcutButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 148).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let cell = button.cell as? NSButtonCell {
            cell.wraps = false
            cell.lineBreakMode = .byTruncatingTail
            cell.usesSingleLineMode = true
        }
    }

    private func buildHeadsetTab() {
        WireUI.configureSwitch(headsetControlsSwitch, target: self, action: #selector(toggleHeadsetControls))
        headsetModePopup.addItems(withTitles: HeadsetButtonMode.allCases.map(\.title))
        headsetModePopup.target = self
        headsetModePopup.action = #selector(changeHeadsetMode)
        headsetModePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        WireUI.configureSwitch(sendEnterAfterPasteSwitch, target: self, action: #selector(toggleSendEnterAfterPaste))
        WireUI.configureSwitch(airPodsControlSwitch, target: self, action: #selector(toggleAirPodsControl))
        WireUI.configureInfoButton(headsetControlsInfoButton, target: self, action: #selector(showHeadsetControlsInfo), accessibilityDescription: "Headset controls details")
        WireUI.configureInfoButton(sendEnterInfoButton, target: self, action: #selector(showSendEnterInfo), accessibilityDescription: "Wired sends Return details")
        WireUI.configureInfoButton(airPodsInfoButton, target: self, action: #selector(showAirPodsInfo), accessibilityDescription: "Experimental AirPods details")

        let wiredButtonRow = WireUI.menuRow(symbol: "headphones", title: "Wired button", trailing: headsetModePopup)
        let sendEnterRow = WireUI.menuRow(symbol: "return", title: "Wired sends Return", trailing: WireUI.trailingGroup([sendEnterInfoButton, sendEnterAfterPasteSwitch]))
        let airPodsControlRow = WireUI.menuRow(symbol: "airpodspro", title: "AirPods controls (experimental)", trailing: WireUI.trailingGroup([airPodsInfoButton, airPodsControlSwitch]))
        headsetSettingsRows = [wiredButtonRow, airPodsControlRow, sendEnterRow]

        let controlsRows = [
            WireUI.menuRow(symbol: "switch.2", title: "Headset controls", trailing: WireUI.trailingGroup([headsetControlsInfoButton, headsetControlsSwitch]))
        ]
        headsetStack.addArrangedSubview(WireUI.settingsGroup(title: "Controls", rows: controlsRows))
        headsetStack.addArrangedSubview(WireUI.settingsGroup(title: "Wired Headset", rows: [wiredButtonRow, sendEnterRow]))
        headsetStack.addArrangedSubview(WireUI.settingsGroup(title: "AirPods", rows: [airPodsControlRow]))
    }

    private func buildComputerTab() {
        WireUI.configureSwitch(computerControlsSwitch, target: self, action: #selector(toggleComputerControls))
        WireUI.configureInfoButton(computerInfoButton, target: self, action: #selector(showComputerInfo), accessibilityDescription: "Computer mode details")
        WireUI.configureSwitch(computerCustomHarnessSwitch, target: self, action: #selector(toggleComputerCustomHarness))
        WireUI.configureInfoButton(computerHarnessInfoButton, target: self, action: #selector(showComputerHarnessInfo), accessibilityDescription: "Custom harness details")
        WireUI.configureSwitch(computerAutoEnableSwitch, target: self, action: #selector(toggleComputerAutoEnable))
        WireUI.configureInfoButton(computerAutoEnableInfoButton, target: self, action: #selector(showComputerAutoEnableInfo), accessibilityDescription: "Voice trigger details")

        computerHarnessField.placeholderString = "codex --yolo -c 'model_reasoning_effort=\"low\"' e {{prompt}}"
        computerHarnessField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        computerHarnessField.bezelStyle = .roundedBezel
        computerHarnessField.focusRingType = .default
        computerHarnessField.controlSize = .small
        computerHarnessField.delegate = self
        computerHarnessField.target = self
        computerHarnessField.action = #selector(updateComputerHarnessCommand)

        for field in [computerAutoEnableField, computerAutoDisableField] {
            field.placeholderString = "At least two words"
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.focusRingType = .default
            field.controlSize = .small
            field.delegate = self
            field.target = self
        }
        for field in [computerAutoEnableField, computerAutoDisableField] {
            field.widthAnchor.constraint(equalToConstant: 168).isActive = true
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        computerHarnessField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        computerHarnessField.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        computerHarnessField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        computerAutoEnableField.action = #selector(updateComputerAutoEnablePhrase)
        computerAutoDisableField.action = #selector(updateComputerAutoDisablePhrase)

        let customHarnessToggleRow = WireUI.menuRow(symbol: "terminal", title: "Custom harness", trailing: WireUI.trailingGroup([computerHarnessInfoButton, computerCustomHarnessSwitch]))
        let commandRow = WireUI.fullWidthFieldRow(symbol: "chevron.right.square", title: "Command", field: computerHarnessField)
        let autoEnableToggleRow = WireUI.menuRow(symbol: "bolt.badge.automatic", title: "Auto enable", trailing: WireUI.trailingGroup([computerAutoEnableInfoButton, computerAutoEnableSwitch]))
        let enablePhraseRow = WireUI.menuRow(symbol: "text.cursor", title: "Enable phrase", trailing: computerAutoEnableField)
        let disablePhraseRow = WireUI.menuRow(symbol: "text.cursor", title: "Disable phrase", trailing: computerAutoDisableField)
        computerModeRows = [customHarnessToggleRow]
        computerHarnessRows = [commandRow]
        computerAutoEnableRows = [enablePhraseRow, disablePhraseRow]

        computerStack.addArrangedSubview(WireUI.settingsGroup(title: "Computer Mode", rows: [
            WireUI.menuRow(symbol: "desktopcomputer", title: "Computer mode (dangerous)", trailing: WireUI.trailingGroup([computerInfoButton, computerControlsSwitch])),
            customHarnessToggleRow,
            commandRow
        ]))
        computerStack.addArrangedSubview(WireUI.settingsGroup(title: "Voice Triggers", rows: [
            autoEnableToggleRow,
            enablePhraseRow,
            disablePhraseRow
        ]))
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
            let autoDisablePhrase = self.computerAutoDisableField.currentEditor() == nil
                ? self.state.computerAutoDisablePhrase
                : self.computerAutoDisableField.stringValue
            let hasInvalidAutoEnablePhrase = self.state.computerAutoEnableEnabled && self.autoEnablePhraseWordCount(autoEnablePhrase) < 2
            let hasInvalidAutoDisablePhrase = self.state.computerAutoEnableEnabled
                && !autoDisablePhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && self.autoEnablePhraseWordCount(autoDisablePhrase) < 2
            let hasInvalidAutoPhrase = hasInvalidAutoEnablePhrase || hasInvalidAutoDisablePhrase
            self.footerStatusLabel.stringValue = hasInvalidAutoEnablePhrase
                ? "Minimum 2 words"
                : hasInvalidAutoDisablePhrase
                ? "Disable phrase needs 2 words"
                : (self.state.statusText.isEmpty ? "Ready" : self.state.statusText)
            self.footerStatusLabel.textColor = hasInvalidAutoPhrase ? .systemRed : .secondaryLabelColor
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

            self.headsetControlsSwitch.state = self.state.headsetControlsEnabled ? .on : .off
            self.headsetModePopup.selectItem(at: self.headsetProbeManager.currentMode.rawValue)
            self.airPodsControlSwitch.state = self.headsetProbeManager.isAirPodsControlEnabled ? .on : .off
            self.sendEnterAfterPasteSwitch.state = self.state.sendEnterAfterPaste ? .on : .off
            self.cleanupSwitch.state = self.state.cleanupEnabled ? .on : .off
            self.backgroundPasteSwitch.state = self.state.backgroundPasteEnabled ? .on : .off
            self.computerControlsSwitch.state = self.state.computerControlsEnabled ? .on : .off
            self.computerCustomHarnessSwitch.state = self.state.computerCustomHarnessEnabled ? .on : .off
            self.computerAutoEnableSwitch.state = self.state.computerAutoEnableEnabled ? .on : .off
            if self.computerAutoEnableField.currentEditor() == nil {
                self.computerAutoEnableField.stringValue = self.state.computerAutoEnablePhrase
            }
            if self.computerAutoDisableField.currentEditor() == nil {
                self.computerAutoDisableField.stringValue = self.state.computerAutoDisablePhrase
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

        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
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

        let label = NSTextField(labelWithString: "Left tap starts or continues dictation.\nRight tap sends Return once after an AirPods transcript.\nRecording stops after a short silence.\nThis mode takes over media controls, so it can interfere with music playback.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 236
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 132))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 260),
            container.heightAnchor.constraint(equalToConstant: 132),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 260, height: 132)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 132)
        popover.contentViewController = controller
        airPodsInfoPopover = popover
        popover.show(relativeTo: airPodsInfoButton.bounds, of: airPodsInfoButton, preferredEdge: .maxY)
    }

    @objc private func toggleSendEnterAfterPaste() {
        (NSApp.delegate as? AppDelegate)?.setSendEnterAfterPaste(sendEnterAfterPasteSwitch.state == .on)
        refresh()
    }

    @objc private func toggleCleanup() {
        (NSApp.delegate as? AppDelegate)?.setCleanupEnabled(cleanupSwitch.state == .on)
        refresh()
    }

    @objc private func showCleanupInfo() {
        showSettingsInfo(
            from: cleanupInfoButton,
            text: "Removes filler words, repeated fragments, and obvious transcription artifacts before pasting or copying the transcript.",
            size: NSSize(width: 258, height: 86)
        )
    }

    @objc private func showHeadsetControlsInfo() {
        showSettingsInfo(
            from: headsetControlsInfoButton,
            text: "Enables wired headset button detection and optional AirPods controls. Turn this off if media controls or headset buttons behave unexpectedly.",
            size: NSSize(width: 270, height: 104)
        )
    }

    @objc private func showSendEnterInfo() {
        showSettingsInfo(
            from: sendEnterInfoButton,
            text: "After a wired headset recording is pasted, wire also sends Return. This is useful for chat inputs that submit with Return.",
            size: NSSize(width: 270, height: 92)
        )
    }

    @objc private func showComputerAutoEnableInfo() {
        showSettingsInfo(
            from: computerAutoEnableInfoButton,
            text: "When enabled, wire listens for the enable phrase while Computer mode is off and the disable phrase while it is on. Phrases need at least two words.",
            size: NSSize(width: 280, height: 110)
        )
    }

    private func showSettingsInfo(from button: NSButton, text: String, size: NSSize) {
        if let settingsInfoPopover, settingsInfoPopover.isShown {
            settingsInfoPopover.performClose(nil)
            return
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = size.width - 24
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = size

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = size
        popover.contentViewController = controller
        settingsInfoPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    @objc private func toggleBackgroundPaste() {
        (NSApp.delegate as? AppDelegate)?.setBackgroundPasteEnabled(backgroundPasteSwitch.state == .on)
        refresh()
    }

    @objc private func showBackgroundPasteInfo() {
        if let backgroundPasteInfoPopover, backgroundPasteInfoPopover.isShown {
            backgroundPasteInfoPopover.performClose(nil)
            return
        }

        let label = NSTextField(labelWithString: "On: paste back into the app and text field where recording started, even if another window is active when transcription finishes.\nOff: copy the transcript, then paste once into the active window at finish time.\nCMUX: enable Automation mode in CMUX for original tab/workspace targeting.")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 236
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 150))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 260),
            container.heightAnchor.constraint(equalToConstant: 150),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 260, height: 150)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 150)
        popover.contentViewController = controller
        backgroundPasteInfoPopover = popover
        popover.show(relativeTo: backgroundPasteInfoButton.bounds, of: backgroundPasteInfoButton, preferredEdge: .maxY)
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

    @objc private func updateComputerAutoDisablePhrase() {
        computerAutoDisableSaveWorkItem?.cancel()
        (NSApp.delegate as? AppDelegate)?.setComputerAutoDisablePhrase(computerAutoDisableField.stringValue)
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
        } else if obj.object as? NSTextField === computerAutoDisableField {
            updateComputerAutoDisablePhrase()
        } else if obj.object as? NSTextField === computerHarnessField {
            updateComputerHarnessCommand()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === computerAutoEnableField {
            scheduleComputerAutoEnablePhraseSave()
            refresh()
        } else if obj.object as? NSTextField === computerAutoDisableField {
            scheduleComputerAutoDisablePhraseSave()
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

    private func scheduleComputerAutoDisablePhraseSave() {
        computerAutoDisableSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.setComputerAutoDisablePhrase(self.computerAutoDisableField.stringValue)
        }
        computerAutoDisableSaveWorkItem = workItem
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

        let label = NSTextField(labelWithString: "When Computer mode is on, each transcript runs through a local shell command with full execution permissions.\nBy default it runs Codex with low reasoning effort.\nAuto enable listens for the enable phrase when mode is off, and the disable phrase when mode is on.")
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

    func collectUISelfTestMetrics(into lines: inout [String]) {
        holdShortcutButton.title = hotKeyManager.holdShortcutDisplay
        toggleShortcutButton.title = hotKeyManager.toggleShortcutDisplay
        lines.append("holdShortcutTitle=\(holdShortcutButton.title)")
        lines.append("toggleShortcutTitle=\(toggleShortcutButton.title)")
        lines.append("holdShortcutFrame=\(holdShortcutButton.frame.integral)")
        lines.append("toggleShortcutFrame=\(toggleShortcutButton.frame.integral)")
        lines.append("holdShortcutLines=\(holdShortcutButton.title.components(separatedBy: "\n").count)")
        lines.append("toggleShortcutLines=\(toggleShortcutButton.title.components(separatedBy: "\n").count)")
    }

    private func captureButton(for target: HotKeyKind) -> NSButton {
        switch target {
        case .toggle:
            return toggleShortcutButton
        case .hold:
            return holdShortcutButton
        }
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
        handleTranscribe(source: "objc-toggle")
    }
}
