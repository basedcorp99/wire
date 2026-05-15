import AppKit
import Carbon
import WebKit
import AVFoundation
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
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeyManager: HotKeyManager!
    private var codexClient: CodexAPIClient!
    private var recorder: AudioRecorder!
    private var statusSpinnerTimer: Timer?
    private var statusSpinnerIndex = 0
    private let statusSpinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Initialize components
        codexClient = CodexAPIClient()
        recorder = AudioRecorder()
        hotKeyManager = HotKeyManager(
            state: state,
            onPressed: { [weak self] in self?.handleHotKeyPressed() },
            onReleased: { [weak self] in self?.handleHotKeyReleased() }
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
            hotKeyManager: hotKeyManager
        )
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 256)
        popover.contentViewController = controller

        state.onChange = { [weak self, weak controller] in
            self?.renderStatusItem()
            controller?.refresh()
        }
        hotKeyManager.registerSavedShortcut()
        if SMAppService.mainApp.status == .notRegistered {
            try? LaunchAtLogin.setEnabled(true)
        }
        scheduleInitialAccessibilityCheck()
        scheduleInitialMicrophoneCheck()

        // Pre-warm the API client and check auth
        Task {
            await initializeSession()
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
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func renderStatusItem() {
        DispatchQueue.main.async {
            let isTranscribing = self.state.transcriptionStage == .transcribing
            if let image = NSImage(systemSymbolName: self.recorder.isRecording ? "mic.circle.fill" : "mic.fill", accessibilityDescription: "wire") {
                image.isTemplate = true
                self.statusItem.button?.image = image
                self.statusItem.button?.imagePosition = .imageLeft
            }
            if isTranscribing {
                self.startStatusSpinner()
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

    private func handleHotKeyPressed() {
        if state.recordingMode == .pushToTalk {
            startRecording(status: "Recording… release shortcut to transcribe")
        } else {
            handleTranscribe()
        }
    }

    private func handleHotKeyReleased() {
        guard state.recordingMode == .pushToTalk else { return }
        guard recorder.isRecording else { return }
        stopAndTranscribe()
    }

    private func handleTranscribe() {
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            startRecording(status: "Recording… press shortcut again to stop")
        }
    }

    private func startRecording(status: String) {
        Task { @MainActor in
            guard !recorder.isRecording else { return }
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

            do {
                try recorder.start()
            } catch {
                state.statusText = "Could not start recording: \(error.localizedDescription)"
                state.transcriptionStage = .error(error.localizedDescription)
                state.isBusy = false
            }
        }
    }

    private func stopAndTranscribe() {
        Task { @MainActor in
            guard recorder.isRecording else { return }
            state.statusText = "Loading… transcribing"
            state.transcriptionStage = .transcribing

            let audioData = recorder.stop()

            guard let data = audioData, data.count > 1000 else {
                state.statusText = "Recording too short, try again"
                state.transcriptionStage = .error("Recording too short")
                state.isBusy = false
                return
            }

            guard isLikelySpeechRecording(data) else {
                state.statusText = "Ready"
                state.transcriptionStage = .idle
                state.isBusy = false
                return
            }

            state.statusText = "Loading… uploading \(data.count / 1024) KB"

            do {
                let text = try await codexClient.transcribe(audioData: data)

                state.lastTranscription = text
                state.transcriptionStage = .done
                state.statusText = "Done"

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                typeText(text)
            } catch {
                state.statusText = "Error: \(error.localizedDescription)"
                state.transcriptionStage = .error(error.localizedDescription)
            }
            state.isBusy = false
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

    private func typeText(_ text: String) {
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

enum RecordingMode: Int {
    case toggle = 0
    case pushToTalk = 1
}

final class AppState {
    var onChange: (() -> Void)?

    var isBusy = false { didSet { onChange?() } }
    var statusText = "" { didSet { onChange?() } }
    var lastTranscription = "" { didSet { onChange?() } }
    var transcriptionStage: TranscriptionStage = .idle { didSet { onChange?() } }
    var recordingMode: RecordingMode {
        get { RecordingMode(rawValue: UserDefaults.standard.integer(forKey: "recordingMode")) ?? .toggle }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode")
            onChange?()
        }
    }
}

// MARK: - Audio Recorder

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var tempURL: URL?
    private var timer: Timer?

    var isRecording: Bool { engine?.isRunning ?? false }

    /// Start recording to a temporary WAV file
    func start() throws {
        guard !isRecording else { return }

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

        // Auto-stop after 30 seconds max
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            _ = self?.stopAndTranscribe()
        }
    }

    /// Stop recording and return the audio data
    private func stopAndTranscribe() -> Data? {
        guard let engine = engine, let url = tempURL else { return nil }

        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        outputFile = nil
        self.tempURL = nil

        defer { try? FileManager.default.removeItem(at: url) }
        return normalizedWavData(from: url) ?? (try? Data(contentsOf: url))
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
        const timeout = setTimeout(() => controller.abort(), 45000);
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 55) {
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
            return "Use a shortcut with Command, Control, Option, or Shift."
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

final class PopoverViewController: NSViewController {
    private let state: AppState
    private let hotKeyManager: HotKeyManager
    private let statusLabel = NSTextField(labelWithString: "")
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let transcriptLabel = NSTextField(labelWithString: "No recent transcription")
    private let copyLatestButton = NSButton(title: "", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Toggle", "Hold"], trackingMode: .selectOne, target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()
    private var shortcutMonitor: Any?

    init(state: AppState, hotKeyManager: HotKeyManager) {
        self.state = state
        self.hotKeyManager = hotKeyManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 256))
        visual.material = .menu
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
        root.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
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
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)

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
        root.addArrangedSubview(header)
        root.addArrangedSubview(divider())

        root.addArrangedSubview(sectionLabel("Settings"))
        shortcutButton.target = self
        shortcutButton.action = #selector(captureShortcut)
        root.addArrangedSubview(menuRow(symbol: "keyboard", title: "Shortcut", trailing: shortcutButton))

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        root.addArrangedSubview(menuRow(symbol: "switch.2", title: "Record mode", trailing: modeControl))
        root.addArrangedSubview(spacer(height: 8))

        root.addArrangedSubview(divider())
        root.addArrangedSubview(sectionLabel("Latest"))
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
        root.addArrangedSubview(padded(latestRow, left: 14, right: 14, top: 3, bottom: 8))

        root.addArrangedSubview(divider())
        root.addArrangedSubview(clickableMenuRow(symbol: "power", title: "Quit", action: #selector(quitApp)))
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return padded(label, left: 14, right: 14, top: 8, bottom: 3)
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

    private func menuRow(symbol: String, title: String, trailing: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)

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

    private func clickableMenuRow(symbol: String, title: String, action: Selector) -> NSView {
        let button = HoverMenuButton(title: "", target: self, action: action)
        return clickableMenuRow(symbol: symbol, title: title, button: button)
    }

    private func clickableMenuRow(symbol: String, title: String, button: NSButton) -> NSView {
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
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)

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
        DispatchQueue.main.async {
            self.statusLabel.stringValue = self.state.statusText.isEmpty ? "Ready" : self.state.statusText
            self.shortcutButton.title = self.hotKeyManager.shortcutDisplay
            self.modeControl.selectedSegment = self.state.recordingMode.rawValue

            switch self.state.transcriptionStage {
            case .recording:
                self.loadingIndicator.stopAnimation(nil)
            case .transcribing:
                self.loadingIndicator.startAnimation(nil)
            default:
                self.loadingIndicator.stopAnimation(nil)
            }

            if self.state.transcriptionStage == .transcribing {
                self.transcriptLabel.stringValue = "Loading… transcribing audio"
            } else {
                self.transcriptLabel.stringValue = self.state.lastTranscription.isEmpty ? "No recent transcription" : self.state.lastTranscription
            }
            self.copyLatestButton.isEnabled = !self.state.lastTranscription.isEmpty
        }
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

    @objc private func modeChanged() {
        state.recordingMode = modeControl.selectedSegment == RecordingMode.pushToTalk.rawValue ? .pushToTalk : .toggle
        state.statusText = state.recordingMode == .pushToTalk ? "Push-to-talk: hold shortcut to record" : "Toggle: press once to start, again to stop"
    }

    @objc private func captureShortcut() {
        guard shortcutMonitor == nil else { return }
        hotKeyManager.suspendShortcut()
        shortcutButton.title = "Press keys…"
        state.statusText = "Press new shortcut…"
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.stopShortcutCapture(event: event)
            return nil
        }
    }

    private func stopShortcutCapture(event: NSEvent) {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        if event.keyCode == UInt16(kVK_Escape) {
            hotKeyManager.registerSavedShortcut()
            state.statusText = "Shortcut unchanged"
            refresh()
            return
        }

        do {
            try hotKeyManager.updateShortcut(from: event)
            state.statusText = "Shortcut saved"
        } catch {
            hotKeyManager.registerSavedShortcut()
            state.statusText = "Shortcut failed: \(error.localizedDescription)"
        }
        refresh()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - HotKey Manager

final class HotKeyManager {
    private let state: AppState
    private let onPressed: () -> Void
    private let onReleased: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(state: AppState, onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) {
        self.state = state
        self.onPressed = onPressed
        self.onReleased = onReleased
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    var shortcutDisplay: String {
        let savedKey = UserDefaults.standard.object(forKey: "hotKeyCode") as? Int
        let savedModifiers = UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int
        let keyCode = UInt32(savedKey ?? kVK_ANSI_M)
        let modifiers = UInt32(savedModifiers ?? (cmdKey | shiftKey))
        return display(modifiers: modifiers, keyCode: keyCode)
    }

    func registerSavedShortcut() {
        let keyCode = UInt32(UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? kVK_ANSI_M)
        let modifiers = UInt32(UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int ?? (cmdKey | shiftKey))
        register(keyCode: keyCode, modifiers: modifiers)
    }

    func suspendShortcut() {
        unregister()
    }

    func updateShortcut(from event: NSEvent) throws {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else { throw AppError.hotKeyUnsupported }
        let keyCode = UInt32(event.keyCode)
        UserDefaults.standard.set(Int(keyCode), forKey: "hotKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotKeyModifiers")
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x54524E53), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        state.statusText = status == noErr ? "Shortcut: \(display(modifiers: modifiers, keyCode: keyCode))" : "Shortcut registration failed: \(status)"
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed):
                manager.onPressed()
            case UInt32(kEventHotKeyReleased):
                manager.onReleased()
            default:
                break
            }
            return noErr
        }, eventTypes.count, &eventTypes, pointer, &eventHandler)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private func display(modifiers: UInt32, keyCode: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: "-")
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
