import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import ImageIO

// MARK: - Constants

private let schemaVersion = 1
private let pluginName = "WhatsApp Call"
private let activityID = "whatsapp-call.active-call"
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"
private let settingsPathEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_PATH"
private let pluginPackageEnvironmentKey = "DYNAMICLAKE_PLUGIN_PACKAGE"
private let testSessionEnvironmentKey = "DYNAMICLAKE_WHATSAPP_CALL_TEST_SESSION"
private let maxFrameSize = 64 * 1024
private let fieldSeparator = "<<<DYNAMICLAKE_FIELD>>>"
private let timerMaximumDuration: TimeInterval = 48 * 60 * 60
private let actionLoopInterval: TimeInterval = 0.05

/// Cadence of the waveform animation: fast enough to read as movement, slow
/// enough that the inline PNG frames stay cheap on the local socket.
private let waveformInterval: TimeInterval = 0.12
/// Bars per side — the far end on the left in green, your microphone on the right in orange.
private let waveformBarsPerSide = 7
private let waveformWidth = 100
private let waveformHeight = 28

/// Silence required before a dismissal of a known call is forgotten, so the
/// next call in the same app shows again. One quiet poll is already a closed
/// window; the small margin absorbs a single failed detection.
private let quietForgetSeconds: TimeInterval = 3
/// The same, for URL-only detection: it drops out and returns every couple of
/// seconds, so only a long stretch of silence counts as "the tab is gone".
private let statelessQuietSeconds: TimeInterval = 60
/// How long after a call ends a URL-only tab is assumed to be its leftover
/// rather than a new call.
private let leftoverWatchSeconds: TimeInterval = 45

/// AXIdentifier of the group WhatsApp mounts in its call window. Identifiers are
/// not localized, which is why detection uses it instead of the window title.
private let callWindowIdentifier = "Calling_Window"
private let whatsappBundleIdentifier = "net.whatsapp.WhatsApp"

private let safariJavaScriptHint = "Safari ▸ Settings ▸ Advanced ▸ Show features for web developers, then Develop ▸ Developer Settings ▸ Allow JavaScript from Apple Events"
private let chromeJavaScriptHint = "Chrome (and other Chromium browsers) ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events"

private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

// MARK: - Settings

private struct PluginSettings: Equatable, CustomStringConvertible {
    var pollSeconds: TimeInterval = 1
    var detectNativeCalls = true
    var detectWebCalls = true
    var webUrlFallback = true
    var diagnosticActivity = false
    var showWaveform = true
    var captureAppAudio = false
    var compactPresentation = "Phone + time"
    var displaysWaveform: Bool { showWaveform && compactPresentation == "Phone + waveform" }

    var description: String {
        "PluginSettings(pollSeconds: \(pollSeconds), detectNativeCalls: \(detectNativeCalls), detectWebCalls: \(detectWebCalls), webUrlFallback: \(webUrlFallback), diagnosticActivity: \(diagnosticActivity), showWaveform: \(showWaveform), captureAppAudio: \(captureAppAudio), compactPresentation: \(compactPresentation))"
    }
}

private func environmentSettingKey(for id: String) -> String {
    var key = ""
    for scalar in id.unicodeScalars {
        if CharacterSet.uppercaseLetters.contains(scalar), !key.isEmpty, !key.hasSuffix("_") {
            key.append("_")
        }

        if CharacterSet.alphanumerics.contains(scalar) {
            key.append(String(scalar).uppercased())
        } else if !key.hasSuffix("_") {
            key.append("_")
        }
    }

    return "DYNAMICLAKE_SETTING_\(key.trimmingCharacters(in: CharacterSet(charactersIn: "_")))"
}

private func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }
    return defaultValue
}

private func doubleValue(_ value: Any?, default defaultValue: Double, minimum: Double, maximum: Double) -> Double {
    let raw: Double?
    if let value = value as? NSNumber {
        raw = value.doubleValue
    } else if let value = value as? String {
        raw = Double(value)
    } else {
        raw = nil
    }

    guard let raw, raw.isFinite else { return defaultValue }
    return min(max(raw, minimum), maximum)
}

private func settingValue(_ values: [String: Any], id: String, default defaultValue: Any) -> Any {
    // The settings file is rewritten live on every change; the environment
    // variable is a snapshot from launch, so the file wins when present.
    values[id] ?? ProcessInfo.processInfo.environment[environmentSettingKey(for: id)] ?? defaultValue
}

private func loadSettings(previous: PluginSettings? = nil) -> PluginSettings {
    var values: [String: Any] = [:]

    if let settingsPath = ProcessInfo.processInfo.environment[settingsPathEnvironmentKey] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return previous ?? PluginSettings()
        }
        values = (dictionary["values"] as? [String: Any]) ?? dictionary
    }

    return PluginSettings(
        pollSeconds: doubleValue(settingValue(values, id: "pollSeconds", default: 1), default: 1, minimum: 0.5, maximum: 5),
        detectNativeCalls: boolValue(settingValue(values, id: "detectNativeCalls", default: true), default: true),
        detectWebCalls: boolValue(settingValue(values, id: "detectWebCalls", default: true), default: true),
        webUrlFallback: boolValue(settingValue(values, id: "webUrlFallback", default: true), default: true),
        diagnosticActivity: boolValue(settingValue(values, id: "diagnosticActivity", default: false), default: false),
        showWaveform: boolValue(settingValue(values, id: "showWaveform", default: true), default: true),
        captureAppAudio: boolValue(settingValue(values, id: "captureAppAudio", default: false), default: false),
        compactPresentation: settingValue(values, id: "compactPresentation", default: "Phone + time") as? String ?? "Phone + time"
    )
}

// MARK: - Errors

private enum PluginError: Error, CustomStringConvertible {
    case socketPathMissing
    case socket(String)
    case frameTooLarge(Int)
    case invalidJSON

    var description: String {
        switch self {
        case .socketPathMissing:
            return "\(socketEnvironmentKey) is missing"
        case .socket(let message):
            return message
        case .frameTooLarge(let size):
            return "JSON frame is too large: \(size) bytes"
        case .invalidJSON:
            return "failed to encode JSON payload"
        }
    }
}

// MARK: - Socket

private final class JSONSocketClient {
    let socketPath: String
    private var fileDescriptor: Int32 = -1
    private var readBuffer = Data()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit { close() }

    func connect() throws {
        guard socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw PluginError.socket("socket path too long")
        }
        fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw PluginError.socket("socket failed: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)

        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    memset(destination, 0, maxPathLength)
                    strncpy(destination, source, maxPathLength - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            throw PluginError.socket("connect failed: \(String(cString: strerror(errno)))")
        }

        var noSignal: Int32 = 1
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= maxFrameSize else {
            throw PluginError.frameTooLarge(data.count)
        }

        var frame = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(data)
        try sendAll(frame)
    }

    func receiveAvailable() throws -> [[String: Any]] {
        guard fileDescriptor >= 0 else { return [] }

        var temporary = [UInt8](repeating: 0, count: 4096)
        while true {
            let capacity = temporary.count
            let count = temporary.withUnsafeMutableBytes { pointer in
                Darwin.recv(fileDescriptor, pointer.baseAddress, capacity, 0)
            }

            if count > 0 {
                readBuffer.append(temporary, count: count)
                if readBuffer.count > maxFrameSize * 4 {
                    throw PluginError.socket("incoming buffer limit exceeded")
                }
                continue
            }

            if count == 0 { throw PluginError.socket("host disconnected") }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw PluginError.socket("receive failed")
        }

        var messages: [[String: Any]] = []
        while readBuffer.count >= 4 {
            let lengthData = readBuffer.prefix(4)
            let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length > maxFrameSize {
                throw PluginError.frameTooLarge(Int(length))
            }

            let totalLength = Int(length) + 4
            guard readBuffer.count >= totalLength else { break }

            let body = readBuffer.subdata(in: 4..<totalLength)
            readBuffer.removeSubrange(0..<totalLength)

            if let object = try? JSONSerialization.jsonObject(with: body, options: []),
               let dictionary = object as? [String: Any] {
                messages.append(dictionary)
            }
        }

        return messages
    }

    private func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 2

            while sent < data.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), data.count - sent, 0)
                if result > 0 {
                    sent += result
                    continue
                }
                if result < 0 && errno == EINTR { continue }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw PluginError.socket("send timed out")
                    }
                    usleep(10_000)
                    continue
                }
                throw PluginError.socket("send failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Logging

/// Logs live in Application Support. Writing inside the installed package is
/// forbidden by the packaging rules and breaks updates.
private func debugLogPath() -> URL {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = applicationSupport
        .appendingPathComponent("DynamicLake", isDirectory: true)
        .appendingPathComponent("PluginLogs", isDirectory: true)

    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("whatsapp-call-debug.log")
}

private func debugLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let url = debugLogPath()

    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
        try? FileManager.default.removeItem(at: url)
    }

    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Process helpers

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private var browserScanDeadline: Date?

private func runProcess(executable: String, arguments: [String], timeout: TimeInterval, context: String? = nil) -> ProcessResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whatsapp-process-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { return nil }
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
          let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else { return nil }
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    defer { try? stdoutHandle.close(); try? stderrHandle.close() }

    do {
        try process.run()
    } catch {
        if let context {
            debugLog("process failed context=\(context) error=\(error.localizedDescription)")
        }
        return nil
    }

    let deadline = min(Date().addingTimeInterval(timeout), browserScanDeadline ?? .distantFuture)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }

    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.05)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let context {
            debugLog("process timeout context=\(context)")
        }
        return nil
    }

    guard let stdoutReader = try? FileHandle(forReadingFrom: stdoutURL),
          let stderrReader = try? FileHandle(forReadingFrom: stderrURL) else { return nil }
    defer { try? stdoutReader.close(); try? stderrReader.close() }
    let stdoutData = stdoutReader.readData(ofLength: maxFrameSize)
    let stderrData = stderrReader.readData(ofLength: 4096)
    return ProcessResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

private func runAppleScript(_ script: String, timeout: TimeInterval = 3, context: String? = nil) -> String? {
    runAppleScriptCapturingError(script, timeout: timeout, context: context ?? "appleScript").output
}

/// Keeps the failure text so callers can tell a blocked capability (Apple
/// Events permission, JavaScript from Apple Events) apart from a missing tab.
private func runAppleScriptCapturingError(
    _ script: String,
    timeout: TimeInterval,
    context: String
) -> (output: String?, detail: String?) {
    guard let result = runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: timeout, context: context) else {
        return (nil, "timeout")
    }

    guard result.status == 0 else {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .split(separator: "\n")
            .first
            .map(String.init) ?? "unknown"
        debugLog("osascript failed context=\(context) status=\(result.status)")
        return (nil, detail)
    }

    return (result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), nil)
}

private func appleString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// True when the browser refused the script because the developer setting that
/// allows Apple Events to run JavaScript is switched off.
private func safariJavaScriptBlocked(_ detail: String?) -> Bool {
    guard let detail else { return false }
    let lowered = detail.lowercased()
    return lowered.contains("javascript from apple events") || lowered.contains("not allowed")
}

private func appleAppReference(for appName: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/Applications/\(appName).app",
        "\(home)/Applications/\(appName).app",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/\(appName).app",
        "/System/Cryptexes/App/System/Applications/\(appName).app"
    ]

    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return appleString(candidate)
    }

    return appleString(appName)
}

private func appIsRunning(_ appName: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { application in
        if application.localizedName == appName { return true }
        if application.bundleURL?.lastPathComponent == "\(appName).app" { return true }
        if application.executableURL?.lastPathComponent == appName { return true }
        return false
    }
}

/// Per-browser retry delay after its detection script fails or times out, so a
/// browser that never answers (a pending Automation prompt) is not sent a new
/// osascript every poll.
private var detectionBackoff: [String: (failures: Int, retryAt: Date)] = [:]
private let detectionBackoffMaximum: TimeInterval = 60

private func detectionAllowed(for appName: String) -> Bool {
    guard let entry = detectionBackoff[appName] else { return true }
    return Date() >= entry.retryAt
}

private func recordDetection(for appName: String, succeeded: Bool) {
    if succeeded {
        if let entry = detectionBackoff.removeValue(forKey: appName) {
            debugLog("detect \(appName) recovered after \(entry.failures) failures")
        }
        return
    }

    let failures = (detectionBackoff[appName]?.failures ?? 0) + 1
    let delay = min(detectionBackoffMaximum, pow(2, Double(failures - 1)))
    detectionBackoff[appName] = (failures, Date().addingTimeInterval(delay))
    debugLog("detect \(appName) failed \(failures)x; next attempt in \(Int(delay))s")
}

// MARK: - Accessibility helpers

/// Every element gets its own messaging timeout. Without it a stalled WhatsApp
/// would block the poll loop indefinitely: the default wait is unbounded, and
/// one unresponsive node is enough to freeze detection.
private func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    guard ProcessInfo.processInfo.systemUptime < axDeadline else { return nil }
    AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private let axMessagingTimeout: Float = 0.1
private var axDeadline: TimeInterval = 0
private var axNodesRemaining = 0

private func beginAXRead() {
    axDeadline = ProcessInfo.processInfo.systemUptime + 0.8
    axNodesRemaining = 600
}

private func visitAXNode() -> Bool {
    axNodesRemaining -= 1
    return axNodesRemaining >= 0 && ProcessInfo.processInfo.systemUptime < axDeadline
}

private func axString(_ element: AXUIElement, _ name: String) -> String {
    (axAttribute(element, name) as? String) ?? ""
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// WhatsApp prepends U+200E/U+200F direction marks to localized strings.
private func cleanLabel(_ value: String) -> String {
    String(value.unicodeScalars.filter { $0 != "\u{200E}" && $0 != "\u{200F}" })
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedLabel(_ value: String) -> String {
    cleanLabel(value).lowercased()
}

// MARK: - Localized control labels

/// WhatsApp's call controls expose `AXDescription` instead of an `AXIdentifier`,
/// and those descriptions are localized. Two quirks are verified facts, not
/// guesses (checked against the live call UI and the camera's CoreMediaIO
/// streaming state):
///
/// * The microphone description states the current state: `mute on` means the
///   microphone is muted, `mute off` means it is live.
/// * The camera description states the *action*: `camera off` is shown while the
///   camera is on (press it to turn the camera off), `camera on` while it is off.
///   The camera button is built from WhatsApp's VOIP_SWITCH_TO_* strings, which
///   name the action instead of the state.
///
/// Translations for every language ship in WhatsApp's
/// `Localizable.localite.values` files, which are parallel NUL-separated value
/// arrays: the index of `mute on` in the English file is the index of that
/// string in every other language. The plugin reads those indices at runtime so
/// it follows WhatsApp's own translations instead of a hardcoded table.
private struct CallLabels {
    /// Descriptions shown while the microphone is muted.
    var muted: Set<String> = []
    /// Descriptions shown while the microphone is live.
    var live: Set<String> = []
    /// Descriptions shown while the camera is off.
    var cameraOff: Set<String> = []
    /// Descriptions shown while the camera is on.
    var cameraOn: Set<String> = []
    /// Description of the button that leaves the call.
    var leaveCall: Set<String> = []
}

private let englishLabelFields = ["mute on", "mute off", "camera on", "camera off", "leave call"]
private let localiteFileName = "Localizable.localite.values"

private var cachedLabels: CallLabels?
private var labelSource = "not loaded"

private func fallbackLabels() -> CallLabels {
    var labels = CallLabels()
    labels.muted = ["mute on"]
    labels.live = ["mute off"]
    labels.cameraOff = ["camera on"]
    labels.cameraOn = ["camera off"]
    labels.leaveCall = ["leave call"]
    return normalize(labels)
}

private func normalize(_ labels: CallLabels) -> CallLabels {
    var result = CallLabels()
    result.muted = Set(labels.muted.map { $0.lowercased() })
    result.live = Set(labels.live.map { $0.lowercased() })
    result.cameraOff = Set(labels.cameraOff.map { $0.lowercased() })
    result.cameraOn = Set(labels.cameraOn.map { $0.lowercased() })
    result.leaveCall = Set(labels.leaveCall.map { $0.lowercased() })
    return result
}

private func splitLocalite(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self)
        .split(separator: "\0", omittingEmptySubsequences: false)
        .map { cleanLabel(String($0)) }
}

private func loadCallLabels() -> CallLabels {
    if let cachedLabels { return cachedLabels }

    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: whatsappBundleIdentifier) else {
        labelSource = "fallback English (WhatsApp.app not found)"
        cachedLabels = fallbackLabels()
        return cachedLabels!
    }

    let resources = appURL.appendingPathComponent("Contents/Resources")
    let englishFile = resources.appendingPathComponent("en.lproj/\(localiteFileName)")

    guard let englishData = try? Data(contentsOf: englishFile) else {
        labelSource = "fallback English (no English localization file)"
        cachedLabels = fallbackLabels()
        return cachedLabels!
    }

    let englishFields = splitLocalite(englishData)
    var indices: [Int] = []
    // The four state labels are required. "leave call" is optional: losing it
    // only costs the end-call button, so it must not discard the translations.
    for field in englishLabelFields.prefix(4) {
        guard let index = englishFields.firstIndex(where: { $0 == field }) else {
            labelSource = "fallback English (\"\(field)\" not found; WhatsApp may have changed its bundle)"
            cachedLabels = fallbackLabels()
            return cachedLabels!
        }
        indices.append(index)
    }
    let leaveIndex = englishFields.firstIndex(where: { $0 == "leave call" })

    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) else {
        labelSource = "fallback English (resources unreadable)"
        cachedLabels = fallbackLabels()
        return cachedLabels!
    }

    var labels = CallLabels()
    var languages = 0
    for directory in entries where directory.pathExtension == "lproj" {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(localiteFileName)) else { continue }
        let fields = splitLocalite(data)
        guard let muted = indices[safe: 0].flatMap({ fields[safe: $0] }),
              let live = indices[safe: 1].flatMap({ fields[safe: $0] }),
              let cameraOfferedOn = indices[safe: 2].flatMap({ fields[safe: $0] }),
              let cameraOfferedOff = indices[safe: 3].flatMap({ fields[safe: $0] }) else { continue }

        guard !muted.isEmpty, !live.isEmpty, !cameraOfferedOn.isEmpty, !cameraOfferedOff.isEmpty else { continue }

        // English field order: "mute on", "mute off", "camera on", "camera off".
        labels.muted.insert(muted)
        labels.live.insert(live)
        labels.cameraOff.insert(cameraOfferedOn)
        labels.cameraOn.insert(cameraOfferedOff)
        if let leaveIndex, let leave = fields[safe: leaveIndex], !leave.isEmpty {
            labels.leaveCall.insert(leave)
        }
        languages += 1
    }

    guard languages > 0 else {
        labelSource = "fallback English (no translations readable)"
        cachedLabels = fallbackLabels()
        return cachedLabels!
    }

    if labels.leaveCall.isEmpty {
        labels.leaveCall.insert("leave call")
    }

    labelSource = "\(languages) languages read from WhatsApp.app"
    cachedLabels = normalize(labels)
    return cachedLabels!
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// MARK: - Waveform

/// The IOProc for a process tap is a C function pointer and may not capture
/// context, so its measurements go into these file-scope boxes.
private final class TapReading {
    var level: Float = 0
    var frames: Int = 0
}
private let tapReading = TapReading()
private let tapReadingLock = NSLock()

private func audioObjectString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = "" as CFString
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return value as String
}

private func defaultOutputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                     0, nil, &size, &device) == noErr, device != 0 else { return nil }
    return audioObjectString(device, selector: kAudioDevicePropertyDeviceUID)
}

/// Measures the two voices the waveform draws:
///
/// - **orange** — your microphone, so it only moves when you actually talk.
/// - **green** — the call application's *output* stream, which during a call
///   is the other participant's voice. It is read with a CoreAudio process tap
///   pointed at WhatsApp (or the browser on the web), so music in another app
///   never lights it up.
///
/// Sources are opened when a call starts and closed when it ends. Anything
/// that fails — no microphone permission, no audio process — simply leaves
/// that side of the waveform flat rather than breaking the activity.
private final class WaveformMeter {
    private let lock = NSLock()
    private var micLevel: Float = 0
    private var otherLevel: Float = 0
    private var micRunning = false
    private var micFrames = 0
    private var otherFrames = -1
    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    /// The process the open tap listens to, and when each source last tried.
    private var tapPID: pid_t = 0
    private var micLastAttempt = Date.distantPast
    private var tapLastAttempt = Date.distantPast

    struct Snapshot {
        let mic: Float
        let other: Float
        let micRunning: Bool
        let micFrames: Int
        let otherRunning: Bool
    }

    var snapshot: Snapshot {
        lock.lock()
        let mic = micLevel
        let micOn = micRunning
        let micCount = micFrames
        lock.unlock()

        tapReadingLock.lock()
        let frames = tapReading.frames
        let raw = tapReading.level
        tapReadingLock.unlock()

        // A tap that stopped delivering frames means the app closed its audio
        // stream, not that the other person went quiet — decay instead of
        // holding the last value.
        lock.lock()
        if frames == otherFrames && otherFrames != -1 {
            otherLevel *= 0.5
            if otherLevel < 0.001 { otherLevel = 0 }
        } else {
            otherLevel = raw
        }
        otherFrames = frames
        let other = otherLevel
        lock.unlock()

        return Snapshot(mic: micOn ? mic : 0, other: other, micRunning: micOn, micFrames: micCount, otherRunning: frames > 0)
    }

    /// Opens whatever is missing. The microphone belongs to this process rather
    /// than to the call, so it stays open while detection flips between the
    /// desktop app and a browser tab — only the process tap is retargeted.
    func ensureRunning(targetPID pid: pid_t, micWanted: Bool, tapWanted: Bool) {
        lock.lock()
        let micOpen = engine != nil
        let micRetryDue = Date().timeIntervalSince(micLastAttempt) >= 5
        let tapForPID = tapPID == pid && tapID != 0
        let tapRetryDue = Date().timeIntervalSince(tapLastAttempt) >= 5
        lock.unlock()

        if micWanted && microphoneCaptureAllowed(AVCaptureDevice.authorizationStatus(for: .audio)) {
            if !micOpen && micRetryDue {
                startMicrophone()
                lock.lock()
                if engine == nil { micLastAttempt = Date().addingTimeInterval(55) }
                lock.unlock()
            }
        } else if micOpen {
            // Muted, or state unknown: the green side is drawn flat anyway, so
            // keeping an input stream open only costs memory for nothing.
            stopMicrophone()
        }

        if !tapWanted {
            if tapID != 0 { stopTap() }
            tapPID = 0
        } else if !tapForPID, tapPID != pid || tapRetryDue {
            startProcessTap(pid: pid)
            lock.lock()
            if tapID == 0 { tapLastAttempt = Date().addingTimeInterval(55) }
            lock.unlock()
        }
    }

    func stop() {
        stopMicrophone()
        stopTap()
        tapPID = 0

        lock.lock()
        micLevel = 0
        otherLevel = 0
        micRunning = false
        otherFrames = -1
        lock.unlock()
    }

    private func stopMicrophone() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        lock.lock()
        micRunning = false
        micLevel = 0
        micFrames = 0
        lock.unlock()
    }

    private func stopTap() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0

        tapReadingLock.lock()
        tapReading.level = 0
        tapReading.frames = 0
        tapReadingLock.unlock()
    }

    private func startMicrophone() {
        guard microphoneCaptureAllowed(AVCaptureDevice.authorizationStatus(for: .audio)), engine == nil else { return }
        micLastAttempt = Date()
        let audioEngine = AVAudioEngine()
        do {
            let format = audioEngine.inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { return }
            audioEngine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                let samples = channels[0]
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                var sum: Float = 0
                for index in 0..<frames { let sample = samples[index]; sum += sample * sample }
                let rms = sqrtf(sum / Float(frames))
                self.lock.lock()
                self.micLevel = rms
                self.micFrames += 1
                self.lock.unlock()
            }
            try audioEngine.start()
        } catch {
            debugLog("waveform: microphone unavailable (\(error))")
            audioEngine.inputNode.removeTap(onBus: 0)
            return
        }

        engine = audioEngine
        lock.lock()
        micRunning = true
        lock.unlock()
        debugLog("waveform: microphone meter running")
    }

    private func startProcessTap(pid: pid_t) {
        stopTap()
        tapPID = pid
        tapLastAttempt = Date()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var processObject = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var processID = pid
        _ = withUnsafePointer(to: &processID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pointer, &size, &processObject)
        }
        guard processObject != 0 else {
            debugLog("waveform: process \(pid) has no audio client yet")
            return
        }

        let description = CATapDescription()
        description.processes = [processObject]
        description.isExclusive = false   // tap the listed process, not everything else
        description.isMono = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != 0 else {
            debugLog("waveform: process tap failed (\(tapStatus))")
            return
        }
        tapID = tap

        // The aggregate composition wants CFDictionaries keyed by "uid" — the
        // header text says CFDictionaries, not the AudioObjectIDs the docs
        // suggest, and passing IDs silently yields a device with no streams.
        guard let tapUID = audioObjectString(tap, selector: kAudioTapPropertyUID),
              let outputUID = defaultOutputDeviceUID() else {
            debugLog("waveform: could not describe the tap")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return
        }

        var aggregate = AudioObjectID(0)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicLakeWhatsAppWave",
            kAudioAggregateDeviceUIDKey: "com.dynamiclake.plugins.whatsapp-call.\(UUID().uuidString)",
            kAudioAggregateDeviceTapListKey: [["uid": tapUID, "drift": true]],
            kAudioAggregateDeviceSubDeviceListKey: [["uid": outputUID]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != 0 else {
            debugLog("waveform: aggregate device failed (\(aggregateStatus))")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return
        }
        aggregateID = aggregate

        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, _ -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            var peak: Float = 0
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                var sum: Float = 0
                for index in 0..<frames { let sample = samples[index]; sum += sample * sample }
                peak = max(peak, sqrtf(sum / Float(frames)))
            }
            tapReadingLock.lock()
            tapReading.level = peak
            tapReading.frames += 1
            tapReadingLock.unlock()
            return noErr
        }

        var ioProcID: AudioDeviceIOProcID?
        let idStatus = AudioDeviceCreateIOProcID(aggregate, ioProc, nil, &ioProcID)
        guard idStatus == noErr, let ioProcID else {
            debugLog("waveform: IOProc registration failed (\(idStatus))")
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregateID = 0
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return
        }
        self.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregate, ioProcID)
        if startStatus != noErr {
            debugLog("waveform: tap start failed (\(startStatus))")
            AudioDeviceDestroyIOProcID(aggregate, ioProcID)
            self.ioProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregateID = 0
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return
        }

        lock.lock()
        otherFrames = 0
        lock.unlock()
        debugLog("waveform: listening to process \(pid)")
    }
}

/// Linear ramp from −50 dBFS to −10 dBFS. Below the floor the room is silent
/// and the bar sits at its minimum; speech lands in the middle of the range.
private func microphoneCaptureAllowed(_ status: AVAuthorizationStatus) -> Bool {
    status == .authorized
}

private func runAudioCheck() -> Int32 {
    guard microphoneCaptureAllowed(AVCaptureDevice.authorizationStatus(for: .audio)) else {
        print("Microphone check skipped: permission is not already granted; no prompt requested.")
        return 0
    }
    let meter = WaveformMeter()
    defer { meter.stop() }
    meter.ensureRunning(targetPID: 0, micWanted: true, tapWanted: false)
    let deadline = Date().addingTimeInterval(3)
    var peak: Float = 0
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        peak = max(peak, meter.snapshot.mic)
    }
    let result = meter.snapshot
    print("Microphone check: buffers=\(result.micFrames), peak RMS=\(peak), process tap=\(result.otherRunning)")
    return result.micFrames > 0 ? 0 : 1
}

private func normalizedLevel(_ level: Float) -> Float {
    guard level > 0 else { return 0 }
    let decibels = 20 * log10(level)
    return min(max((decibels + 50) / 40, 0), 1)
}

private func renderWaveformPNG(you: [Float], them: [Float], youMuted: Bool) -> Data? {
    let scale = 2
    let width = waveformWidth * scale
    let height = waveformHeight * scale
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.clear(CGRect(x: 0, y: 0, width: waveformWidth, height: waveformHeight))

    let green = CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    let orange = CGColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    let gray = CGColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1)

    let bars = you.count + them.count
    guard bars > 0 else { return nil }
    let gap: CGFloat = 4
    let barWidth = (CGFloat(waveformWidth) - gap * CGFloat(bars - 1)) / CGFloat(bars)
    let midY = CGFloat(waveformHeight) / 2
    let maximum = CGFloat(waveformHeight) - 2
    let minimum: CGFloat = 4
    let radius = min(barWidth / 2, 3)

    func draw(_ index: Int, _ value: Float, _ color: CGColor) {
        let fraction = CGFloat(min(max(value, 0), 1))
        let barHeight = minimum + fraction * (maximum - minimum)
        let x = CGFloat(index) * (barWidth + gap)
        let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    // Far end first (green), local microphone at the end (orange).
    for (index, value) in them.enumerated() {
        draw(index, value, green)
    }
    for (index, value) in you.enumerated() {
        draw(them.count + index, youMuted ? 0 : value, youMuted ? gray : orange)
    }

    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// Which process carries the call audio: WhatsApp itself for a native call,
/// the browser tab's app for a web call. Fake sessions return nil, which leaves
/// the meters closed.
private func waveformTargetPID(for session: CallSession) -> pid_t? {
    if let pid = session.axPID { return pid }

    guard session.kind == "web" else { return nil }

    return NSWorkspace.shared.runningApplications.first { $0.localizedName == session.appName }?
        .processIdentifier
}

    /// Identity of a *call* as far as detection can see it. The same live call
    /// keeps the same token across detection flaps, while a new call or a tab
    /// that now reports a real microphone/camera state gets a different one.
    private func sessionToken(_ session: CallSession) -> String {
        [session.key, session.url ?? "", isStatelessSession(session) ? "fallback" : "known"].joined(separator: "|")
    }

    /// A session with neither microphone nor camera state came from the in-call
    /// URL fallback: nothing in it proves the call is still running, so hiding it
    /// has to survive until the tab reports something else.
    private func isStatelessSession(_ session: CallSession) -> Bool {
        session.kind == "web" && session.micMuted == nil && session.cameraOn == nil
    }

// MARK: - Sessions

private final class CallSession {
    let key: String
    let kind: String
    let title: String
    let url: String?
    let browserName: String
    let appName: String
    let windowIndex: Int?
    let tabIndex: Int?
    /// Present for native sessions; the AX element itself is re-resolved per action.
    let axPID: pid_t?
    var startedAt: TimeInterval
    var micMuted: Bool?
    var cameraOn: Bool?
    /// Free-form state used by `--check` (call window title, web control labels).
    var detail: String = ""

    init(
        key: String,
        kind: String,
        title: String,
        url: String?,
        browserName: String,
        appName: String,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        axPID: pid_t? = nil,
        startedAt: TimeInterval,
        micMuted: Bool? = nil,
        cameraOn: Bool? = nil
    ) {
        self.key = key
        self.kind = kind
        self.title = title
        self.url = url
        self.browserName = browserName
        self.appName = appName
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.axPID = axPID
        self.startedAt = startedAt
        self.micMuted = micMuted
        self.cameraOn = cameraOn
    }

    var elapsedSeconds: Int {
        max(0, Int(Date().timeIntervalSince1970 - startedAt))
    }
}

// MARK: - Native detection

private func whatsappApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == whatsappBundleIdentifier }
}

private func findCallGroup(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth <= 16, visitAXNode() else { return nil }
    if axString(element, "AXIdentifier") == callWindowIdentifier { return element }
    for child in axChildren(element) {
        if let hit = findCallGroup(in: child, depth: depth + 1) { return hit }
    }
    return nil
}

private func collectButtons(in element: AXUIElement, depth: Int = 0, into result: inout [AXUIElement]) {
    guard depth <= 16, visitAXNode() else { return }
    if axString(element, kAXRoleAttribute) == "AXButton" {
        result.append(element)
    }
    for child in axChildren(element) {
        collectButtons(in: child, depth: depth + 1, into: &result)
    }
}

/// Returns the `Calling_Window` group of the front-most call window plus the
/// state of the two controls the plugin mirrors.
private func nativeCallState() -> (group: AXUIElement, windowTitle: String, micMuted: Bool?, cameraOn: Bool?, hasLeaveButton: Bool)? {
    guard AXIsProcessTrusted() else { return nil }
    guard let application = whatsappApplication() else { return nil }

    beginAXRead()
    let axApplication = AXUIElementCreateApplication(application.processIdentifier)
    // A busy WhatsApp must not stall the plugin's poll loop.
    AXUIElementSetMessagingTimeout(axApplication, axMessagingTimeout)

    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApplication, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement] else {
        return nil
    }

    let labels = loadCallLabels()
    for window in windows {
        guard let group = findCallGroup(in: window) else { continue }

        var buttons: [AXUIElement] = []
        collectButtons(in: group, into: &buttons)

        var micMuted: Bool?
        var cameraOn: Bool?
        var hasLeaveButton = false
        for button in buttons {
            let label = normalizedLabel(axString(button, kAXDescriptionAttribute))
            if labels.muted.contains(label) {
                micMuted = true
            } else if labels.live.contains(label) {
                micMuted = false
            } else if labels.cameraOn.contains(label) {
                cameraOn = true
            } else if labels.cameraOff.contains(label) {
                cameraOn = false
            }
            if labels.leaveCall.contains(label) {
                hasLeaveButton = true
            }
        }

        return (group, cleanLabel(axString(window, kAXTitleAttribute)), micMuted, cameraOn, hasLeaveButton)
    }

    return nil
}

private func detectNativeCall() -> CallSession? {
    guard AXIsProcessTrusted() else { return nil }

    guard whatsappApplication() != nil else { return nil }
    guard let state = nativeCallState() else { return nil }

    let session = CallSession(
        key: "native",
        kind: "native",
        title: "WhatsApp",
        url: nil,
        browserName: "WhatsApp",
        appName: "WhatsApp",
        axPID: whatsappApplication()?.processIdentifier,
        startedAt: Date().timeIntervalSince1970,
        micMuted: state.micMuted,
        cameraOn: state.cameraOn
    )
    session.detail = state.windowTitle
    return session
}

/// Presses the native control. The element is resolved again at action time
/// because AX elements go stale whenever WhatsApp rebuilds its call UI.
private func pressNativeControl(pid: pid_t, control: String) -> Bool {
    let labels = loadCallLabels()
    let wanted: Set<String>
    switch control {
    case "mic":
        wanted = labels.muted.union(labels.live)
    case "camera":
        wanted = labels.cameraOn.union(labels.cameraOff)
    case "end":
        wanted = labels.leaveCall
    default:
        return false
    }

    beginAXRead()
    let axApplication = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApplication, axMessagingTimeout)

    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApplication, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let windows = windowsValue as? [AXUIElement] else {
        return false
    }

    for window in windows {
        guard let group = findCallGroup(in: window) else { continue }
        var buttons: [AXUIElement] = []
        collectButtons(in: group, into: &buttons)

        for button in buttons where wanted.contains(normalizedLabel(axString(button, kAXDescriptionAttribute))) {
            AXUIElementSetMessagingTimeout(button, axMessagingTimeout)
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            debugLog("press \(control) -> \(result == .success ? "ok" : "AXPress failed \(result.rawValue)")")
            return result == .success
        }
    }

    // Usually means the call is still connecting: WhatsApp exposes its controls
    // a few seconds after the call window appears.
    debugLog("press \(control) -> control not visible in \(windows.count) window(s)")
    return false
}

// MARK: - Web detection

private struct BrowserSpec {
    let appName: String
    let displayName: String
    /// "safari" uses `do JavaScript`, Chromium browsers use `execute ... javascript`.
    let kind: String
}

private let browserSpecs: [BrowserSpec] = [
    BrowserSpec(appName: "Safari", displayName: "Safari", kind: "safari"),
    BrowserSpec(appName: "Safari Technology Preview", displayName: "Safari Technology Preview", kind: "safari"),
    BrowserSpec(appName: "Google Chrome", displayName: "Chrome", kind: "chrome"),
    BrowserSpec(appName: "Google Chrome Beta", displayName: "Chrome Beta", kind: "chrome"),
    BrowserSpec(appName: "Google Chrome Canary", displayName: "Chrome Canary", kind: "chrome"),
    BrowserSpec(appName: "Microsoft Edge", displayName: "Edge", kind: "chrome"),
    BrowserSpec(appName: "Brave Browser", displayName: "Brave", kind: "chrome"),
    BrowserSpec(appName: "Arc", displayName: "Arc", kind: "chrome"),
    BrowserSpec(appName: "Vivaldi", displayName: "Vivaldi", kind: "chrome"),
    BrowserSpec(appName: "Chromium", displayName: "Chromium", kind: "chrome")
]

private let webURLMarker = "web.whatsapp.com"

private struct WebTab {
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
}

/// Reads a WhatsApp Web tab and reports whether a call is on screen together
/// with whatever the control labels say about the microphone and camera.
///
/// Output: `active|mic|camera|detail`
///   active  - `1` when call controls are visible, otherwise `0`
///   mic     - `muted`, `live` or `unknown`
///   camera  - `on`, `off` or `unknown`
///   detail  - the matched control labels, for `--check` and the debug log
private let webCallStateJavaScript = #"""
(function(){
const vis=function(e){const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>4&&r.height>4&&s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';};
const nm=function(e){return [e.getAttribute('aria-label'),e.getAttribute('data-testid'),e.getAttribute('title'),(e.innerText||'').trim()].filter(Boolean).join(' ').replace(/[|]/g,'/').replace(/\s+/g,' ').trim();};
const els=Array.from(document.querySelectorAll('button,[role="button"],[role="switch"],[data-testid]')).filter(vis);
const blocked=/device|setting|permission|select|choose|screen|share|background|effect|change|more|input|output|speaker|headset|bluetooth|arrow|dropdown|collapse|panel|sidebar|reaction|sticker|emoji|search/i;
const micRe=/microphone|\bmic\b|mute|unmute/i;
const camRe=/camera|video|videocam/i;
const endRe=/end call|leave call|hang up|cancel call|decline|quit call|stop call|end call now/i;
let mic=null,cam=null,end=null;
for(const e of els){
const t=nm(e); if(!t) continue;
if(!end&&endRe.test(t)) end=e;
if(!mic&&micRe.test(t)&&!blocked.test(t)) mic=e;
if(!cam&&camRe.test(t)&&!blocked.test(t)) cam=e;
}
const testids=Array.from(document.querySelectorAll('[data-testid]')).map(function(e){return e.getAttribute('data-testid');}).filter(function(v){return /call/i.test(v);}).slice(0,6);
const active=!!(end&&(mic||cam));
const pressed=function(e){if(!e)return null;const a=e.getAttribute('aria-pressed')||(e.closest('[aria-pressed]')?.getAttribute('aria-pressed'));if(a==='true')return true;if(a==='false')return false;return null;};
let micState='unknown';
if(mic){
const t=nm(mic),p=pressed(mic);
if(p===true) micState='muted';
else if(p===false) micState='live';
else if(/unmute|turn on|enable|start|activate|microphone (on|active)/i.test(t)) micState='muted';
else if(/microphone (off|muted)|is muted|\bmuted\b/i.test(t)) micState='muted';
else if(/\bmute\b|turn off|disable|stop/i.test(t)) micState='live';
}
let camState='unknown';
if(cam){
const t=nm(cam),p=pressed(cam);
if(p===true) camState='on';
else if(p===false) camState='off';
else if(/turn off|disable|stop|camera off|video off|camera is on/i.test(t)) camState='on';
else if(/turn on|enable|start|camera on|video on/i.test(t)) camState='off';
}
const detail=[mic?nm(mic).slice(0,48):'-',cam?nm(cam).slice(0,48):'-',end?nm(end).slice(0,48):'-',testids.join(',')].join(';').replace(/\|/g,'/');
return [active?'1':'0',micState,camState,detail].join('|');
})()
"""#

/// Clicks the WhatsApp Web microphone or camera control.
private let webCallToggleJavaScript = #"""
(function(control){
const vis=function(e){const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>4&&r.height>4&&s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';};
const nm=function(e){return [e.getAttribute('aria-label'),e.getAttribute('data-testid'),e.getAttribute('title'),(e.innerText||'').trim()].filter(Boolean).join(' ');};
const blocked=/device|setting|permission|select|choose|screen|share|background|effect|change|more|input|output|speaker|headset|bluetooth|arrow|dropdown|collapse|panel|sidebar|reaction|sticker|emoji|search/i;
const reMap={camera:/camera|video|videocam/i,end:/end call|leave call|hang up|quit call|stop call/i,mic:/microphone|\bmic\b|mute|unmute/i};
if(location.hostname!=='web.whatsapp.com')return 'wrong host';
const re=reMap[control];if(!re)return 'unsupported';
const els=Array.from(document.querySelectorAll('button,[role="button"],[role="switch"]')).filter(vis);
if(!els.some(e=>/end call|leave call|hang up|quit call|stop call/i.test(nm(e))))return 'no active call';
for(const e of els){
const t=nm(e); if(!t||blocked.test(t)) continue;
if(re.test(t)){ e.click(); return 'clicked '+t.slice(0,60); }
}
return 'missing';
})(#CONTROL#);
"""#

private func webJavaScript(_ body: String, control: String) -> String {
    body.replacingOccurrences(of: "#CONTROL#", with: "\"\(control)\"")
        .split(separator: "\n")
        .joined(separator: " ")
}

private func stateJavaScript() -> String {
    webCallStateJavaScript.split(separator: "\n").joined(separator: " ")
}

private func enumerateWebTabs(spec: BrowserSpec) -> [WebTab] {
    let appReference = appleAppReference(for: spec.appName)
    let titleProperty = spec.kind == "safari" ? "name" : "title"
    let script = """
    tell application "\(appReference)"
        set output to ""
        set fieldSeparator to "\(fieldSeparator)"
        set windowCount to 0
        try
            set windowCount to count of windows
        end try
        repeat with w from 1 to windowCount
            try
                set tabCount to count of tabs of window w
                repeat with t from 1 to tabCount
                    set tabURL to ""
                    try
                        set tabURL to URL of tab t of window w as text
                    end try
                    if tabURL contains "\(webURLMarker)" then
                        set tabTitle to ""
                        try
                            set tabTitle to \(titleProperty) of tab t of window w as text
                        end try
                        set output to output & w & fieldSeparator & t & fieldSeparator & tabTitle & fieldSeparator & tabURL & linefeed
                    end if
                end repeat
            end try
        end repeat
        return output
    end tell
    """

    guard let output = runAppleScript(script, context: "tabs \(spec.appName)") else {
        recordDetection(for: spec.appName, succeeded: false)
        return []
    }
    guard !output.isEmpty else {
        recordDetection(for: spec.appName, succeeded: true)
        return []
    }

    return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        let parts = String(line).components(separatedBy: fieldSeparator)
        guard parts.count == 4, URL(string: parts[3])?.host?.lowercased() == webURLMarker, let windowIndex = Int(parts[0]), let tabIndex = Int(parts[1]) else { return nil }
        return WebTab(windowIndex: windowIndex, tabIndex: tabIndex, title: parts[2], url: parts[3])
    }
}

private func executeWebJavaScript(spec: BrowserSpec, tab: WebTab, script: String) -> (output: String?, detail: String?) {
    let appReference = appleAppReference(for: spec.appName)
    let evaluate = spec.kind == "safari"
        ? "return do JavaScript jsCode in targetTab"
        : "return execute targetTab javascript jsCode"

    let source = """
    tell application "\(appReference)"
        set targetTab to tab \(tab.tabIndex) of window \(tab.windowIndex)
        set jsCode to "\(appleString(script))"
        \(evaluate)
    end tell
    """

    return runAppleScriptCapturingError(source, timeout: 3, context: "javascript \(spec.appName)")
}

private func parseWebState(_ output: String?) -> (active: Bool, micMuted: Bool?, cameraOn: Bool?, detail: String)? {
    guard let output else { return nil }
    let parts = output.components(separatedBy: "|")
    guard parts.count >= 4 else { return nil }

    let mic: Bool?
    switch parts[1] {
    case "muted": mic = true
    case "live": mic = false
    default: mic = nil
    }

    let camera: Bool?
    switch parts[2] {
    case "on": camera = true
    case "off": camera = false
    default: camera = nil
    }

    return (parts[0] == "1", mic, camera, parts[3])
}

/// `web.whatsapp.com/call/...` is WhatsApp Web's in-call URL. It is only a
/// fallback: JavaScript is what actually decides whether a call is live, and
/// this URL shape is used solely when Apple Events JavaScript is unavailable.
private func isWebCallURL(_ url: String) -> Bool {
    guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.lowercased() == webURLMarker else { return false }
    return parsed.path.hasPrefix("/call/")
}

/// Returns only sessions that are really live. A browser that refuses to run
/// JavaScript must never be reported as an active call, otherwise the activity
/// would never be dismissed.
private var nextBrowserScanOffset = 0

private func webSessions(settings: PluginSettings, preferredAppName: String? = nil) -> (sessions: [CallSession], issues: [String]) {
    browserScanDeadline = Date().addingTimeInterval(4)
    defer { browserScanDeadline = nil }
    var sessions: [CallSession] = []
    var issues: [String] = []

    let offset = nextBrowserScanOffset % browserSpecs.count
    var ordered = Array(browserSpecs[offset...] + browserSpecs[..<offset])
    nextBrowserScanOffset = (offset + 1) % browserSpecs.count
    if let preferredAppName, let index = ordered.firstIndex(where: { $0.appName == preferredAppName }) {
        ordered.insert(ordered.remove(at: index), at: 0)
    }
    for spec in ordered {
        guard Date() < (browserScanDeadline ?? .distantFuture) else { break }
        guard appIsRunning(spec.appName) else {
            detectionBackoff[spec.appName] = nil
            continue
        }
        guard detectionAllowed(for: spec.appName) else {
            issues.append("- \(spec.displayName): skipping, still backing off after an earlier failure")
            continue
        }

        let tabs = enumerateWebTabs(spec: spec)
        if tabs.isEmpty {
            issues.append("- \(spec.displayName): no \(webURLMarker) tabs")
            continue
        }

        for tab in tabs {
            guard Date() < (browserScanDeadline ?? .distantFuture) else { break }
            let key = "web:\(spec.appName):\(tab.windowIndex):\(tab.tabIndex)"
            let evaluated = executeWebJavaScript(spec: spec, tab: tab, script: stateJavaScript())

            guard let output = evaluated.output, let state = parseWebState(output) else {
                recordDetection(for: spec.appName, succeeded: false)
                let detail = evaluated.detail ?? "no result"
                issues.append("- \(spec.displayName) window \(tab.windowIndex) tab \(tab.tabIndex): JavaScript unavailable (\(detail))")
                if safariJavaScriptBlocked(detail) {
                    issues.append("  enable: \(spec.kind == "safari" ? safariJavaScriptHint : chromeJavaScriptHint)")
                }

                guard settings.webUrlFallback, isWebCallURL(tab.url) else { continue }
                let fallback = CallSession(
                    key: key,
                    kind: "web",
                    title: "WhatsApp",
                    url: tab.url,
                    browserName: spec.displayName,
                    appName: spec.appName,
                    windowIndex: tab.windowIndex,
                    tabIndex: tab.tabIndex,
                    startedAt: Date().timeIntervalSince1970
                )
                fallback.detail = "URL fallback: \(tab.title)"
                sessions.append(fallback)
                issues.append("  using the in-call URL as a fallback; microphone and camera state unknown")
                continue
            }

            recordDetection(for: spec.appName, succeeded: true)
            guard state.active else { continue }

            let session = CallSession(
                key: key,
                kind: "web",
                title: "WhatsApp",
                url: tab.url,
                browserName: spec.displayName,
                appName: spec.appName,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                startedAt: Date().timeIntervalSince1970,
                micMuted: state.micMuted,
                cameraOn: state.cameraOn
            )
            session.detail = state.detail
            sessions.append(session)
            issues.append("- \(spec.displayName) window \(tab.windowIndex) tab \(tab.tabIndex): ACTIVE \(state.detail)")
        }
    }

    return (sessions, issues)
}

// MARK: - Test sessions

private func testSession() -> CallSession {
    CallSession(
        key: "test:whatsapp-call",
        kind: "test",
        title: "WhatsApp",
        url: nil,
        browserName: "Test",
        appName: "WhatsApp Test",
        startedAt: Date().timeIntervalSince1970,
        micMuted: false,
        cameraOn: true
    )
}

private func diagnosticSession() -> CallSession {
    CallSession(
        key: "diagnostic:whatsapp-call",
        kind: "diagnostic",
        title: "WhatsApp",
        url: nil,
        browserName: "Plugin running",
        appName: "WhatsApp Diagnostic",
        startedAt: Date().timeIntervalSince1970,
        micMuted: true,
        cameraOn: false
    )
}

// MARK: - Payloads

private func iconButton(id: String, systemImage: String, actionID: String, tint: String) -> [String: Any] {
    [
        "type": "button",
        "id": id,
        "systemImage": systemImage,
        "shape": "circle",
        "tint": tint,
        "actionID": actionID
    ]
}

private let bundledIconPNG: Data? = {
    let package = ProcessInfo.processInfo.environment[pluginPackageEnvironmentKey]
        .map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    guard let data = try? Data(contentsOf: package.appendingPathComponent("Assets/WhatsAppLightIcon.png")),
          data.count <= 48 * 1024 else { return nil }
    return data
}()

private func phoneComponent(id: String) -> [String: Any] {
    ["type": "image", "id": id, "source": "sfSymbol", "systemImage": "phone.fill", "tint": "green"]
}

private func pluginIconComponent(id: String) -> [String: Any] {
    guard let data = bundledIconPNG else { return phoneComponent(id: id) }
    return ["type": "image", "id": id, "source": "inlineData", "mimeType": "image/png", "base64Data": data.base64EncodedString()]
}

private func timerComponent(id: String, startedAt: TimeInterval) -> [String: Any] {
    [
        "type": "timer",
        "id": id,
        "startDate": iso8601Formatter.string(from: Date(timeIntervalSince1970: startedAt)),
        "endDate": iso8601Formatter.string(from: Date(timeIntervalSince1970: startedAt + timerMaximumDuration)),
        "countsDown": false,
        "tint": "white"
    ]
}

private func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

/// Native text avoids scaling or clipping a combined icon/time bitmap.
private func elapsedComponent(id: String, session: CallSession) -> [String: Any] {
    ["type": "text", "id": id,
     "text": formatElapsed(Date().timeIntervalSince1970 - session.startedAt),
     "style": "plain", "tint": "green"]
}

/// Compact right slot: the live green/orange waveform. Falls back to the app
/// icon when there is no PNG to show (waveform switched off, render failure).
private func waveformComponent(id: String, png: Data?) -> [String: Any] {
    guard let png else { return pluginIconComponent(id: id) }
    return [
        "type": "image",
        "id": id,
        "source": "inlineData",
        "mimeType": "image/png",
        "base64Data": png.base64EncodedString()
    ]
}

/// Sneak peek centre: where the elapsed time used to live, now the hang-up.
private func endCallButtonComponent(id: String) -> [String: Any] {
    [
        "type": "button",
        "id": id,
        "title": "End",
        "systemImage": "phone.down.fill",
        "shape": "roundedRect",
        "role": "destructive",
        "tint": "red",
        "actionID": "end-call"
    ]
}

/// Compact phone SF Symbol on the left, actual audio levels on the right.
private func compactSurface(session: CallSession, waveform: Data?, showWaveform: Bool) -> [String: Any] {
    [
        "leftSlot": phoneComponent(id: "whatsapp-phone"),
        "rightSlot": showWaveform
            ? waveformComponent(id: "whatsapp-waveform", png: waveform)
            : elapsedComponent(id: "whatsapp-time", session: session)
    ]
}

/// Sent on every waveform tick. Only the compact surface is named, so the sneak
/// peek keeps its microphone, hang-up and camera controls untouched.
private func compactUpdatePayload(session: CallSession, waveform: Data?, showWaveform: Bool) -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "type": "update",
        "activityID": activityID,
        "size": "small",
        "surfaces": [
            "compactLiveActivity": compactSurface(session: session, waveform: waveform, showWaveform: showWaveform)
        ]
    ]
}

private func activityPayload(
    commandType: String,
    session: CallSession,
    waveform: Data?,
    showWaveform: Bool
) -> [String: Any] {
    let micSymbol: String
    let micTint: String
    switch session.micMuted {
    case .some(true):
        micSymbol = "mic.slash.fill"
        micTint = "red"
    case .some(false):
        micSymbol = "mic.fill"
        micTint = "green"
    case nil:
        micSymbol = "mic.fill"
        micTint = "gray"
    }

    let cameraSymbol: String
    let cameraTint: String
    switch session.cameraOn {
    case .some(true):
        cameraSymbol = "video.fill"
        cameraTint = "green"
    case .some(false):
        cameraSymbol = "video.slash.fill"
        cameraTint = "red"
    case nil:
        cameraSymbol = "video.fill"
        cameraTint = "gray"
    }

    return [
        "schemaVersion": schemaVersion,
        "type": commandType,
        "activityID": activityID,
        "title": "WhatsApp",
        "priority": "high",
        "size": "small",
        "surfaces": [
            "compactLiveActivity": compactSurface(session: session, waveform: waveform, showWaveform: showWaveform),
            "extraLiveActivity": [
                "leftSlot": pluginIconComponent(id: "whatsapp-extra-icon")
            ],
            "sneakPeek": [
                "leftSlot": iconButton(id: "whatsapp-mic", systemImage: micSymbol, actionID: "toggle-mic", tint: micTint),
                "center": endCallButtonComponent(id: "whatsapp-end-call"),
                "rightSlot": iconButton(id: "whatsapp-camera", systemImage: cameraSymbol, actionID: "toggle-camera", tint: cameraTint)
            ]
        ]
    ]
}

private func dismissPayload() -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "type": "dismiss",
        "activityID": activityID
    ]
}

// MARK: - Plugin

private final class WhatsAppCallPlugin {
    private let client: JSONSocketClient
    private var currentSession: CallSession?
    private var published = false
    private var lastSignature: String?
    /// What is currently hidden, and since when.
    ///
    /// A bare key was not enough: after the native call window closes, the
    /// detection flaps back to a leftover Safari tab sitting on an in-call URL
    /// and the activity came straight back. `dismissedToken` identifies the call
    /// that was hidden, `hiddenStatelessToken` records the URL-only tab that was
    /// on screen at that moment — it has no state that could prove the call
    /// ended, so it stays hidden until its URL changes.
    private var dismissedToken: String?
    private var dismissedWasStateless = false
    private var hiddenStatelessToken: String?
    private var dismissedMissingSince: Date?
    /// Set while a leftover URL-only tab could still turn up after a call ended.
    private var statelessArmedUntil: Date?
    private var lastSettings: PluginSettings?
    private var lastIssues = ""

    /// Voice activity for the compact waveform.
    private let meter = WaveformMeter()
    private var youHistory: [Float] = []
    private var themHistory: [Float] = []
    private var nextWaveAt = Date.distantPast
    private var cachedWaveformKey: String?
    private var cachedWaveformPNG: Data?
    private var lastWavePNG: Data?
    private var lastWaveElapsed = ""
    private var waveTickCount = 0

    init(client: JSONSocketClient) {
        self.client = client
    }

    func run() throws {
        debugLog("starting swift socket=\(client.socketPath) labels=\(labelSource)")
        try client.connect()
        debugLog("connected")

        defer { meter.stop(); client.close() }
        let watcher = NativeWatcher { [weak self] in self?.nextRefreshNeeded = true }
        var nextRefreshAt = Date.distantPast
        var settings = loadSettings()
        var nextSettingsAt = Date().addingTimeInterval(5)

        while true {
            // Everything Foundation and CoreAudio hands back autoreleased, and
            // there is no run loop here to drain a pool: without this the
            // process grows for as long as it runs.
            try autoreleasepool {
                if Date() >= nextSettingsAt {
                    settings = loadSettings(previous: settings)
                    nextSettingsAt = Date().addingTimeInterval(5)
                }
                watcher.update(enabled: settings.detectNativeCalls)
                if settings != lastSettings {
                    if !settings.diagnosticActivity, dismissedToken?.hasPrefix("diagnostic:") == true {
                        forgetDismissal()
                    }
                    debugLog("settings \(settings)")
                    lastSettings = settings
                    nextRefreshAt = Date.distantPast
                }

                try handleActions(settings: settings)

                // An action (mic, camera, end call) must be reflected immediately,
                // not whenever the next poll happens to come due.
                if nextRefreshNeeded || Date() >= nextRefreshAt {
                    nextRefreshNeeded = false
                    try refresh(settings: settings)
                    nextRefreshAt = Date().addingTimeInterval(monitoringInterval(settings: settings, active: currentSession != nil, appRunning: (settings.detectNativeCalls && whatsappApplication() != nil) || (settings.detectWebCalls && browserSpecs.contains { appIsRunning($0.appName) })))
                }

                // The waveform is the one thing that must keep moving between
                // polls: without it a call looks frozen for a full second at a time.
                if published, let session = currentSession, Date() >= nextWaveAt {
                    nextWaveAt = Date().addingTimeInterval(settings.displaysWaveform ? waveformInterval : 1.0)
                    try waveformTick(session: session, settings: settings)
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(published ? actionLoopInterval : 0.25))
        }
    }

    private func handleActions(settings: PluginSettings) throws {
        for message in try client.receiveAvailable() {
            if logFrame(message) { continue }

            guard (message["type"] as? String) == "action",
                  (message["activityID"] == nil || message["activityID"] as? String == activityID),
                  let actionID = message["actionID"] as? String,
                  let session = currentSession else {
                continue
            }

            debugLog("received action=\(actionID) session=\(session.key)")

            switch actionID {
            case "toggle-mic", "toggle-camera":
                let control = actionID == "toggle-mic" ? "mic" : "camera"
                if toggle(session: session, control: control) {
                    // Re-read the real state instead of guessing what the press did.
                    nextRefreshNeeded = true
                } else {
                    debugLog("action=\(actionID) every toggle path failed")
                    if resolve(session: session, settings: settings) == nil {
                        debugLog("action=\(actionID) dismissed because the call is gone")
                        markDismissed(session, reason: "call is gone")
                        try dismiss()
                    }
                }
            case "dismiss":
                markDismissed(session, reason: "dismissed by the user")
                try dismiss()
            case "end-call":
                if end(session: session) {
                    // Hide on the spot: the call window survives a moment after
                    // End, and seeing the activity update instead of vanish reads
                    // as "it did not hang up".
                    markDismissed(session, reason: "call ended")
                    try dismiss()
                    nextRefreshNeeded = true
                } else {
                    debugLog("action=end-call every path failed")
                    if resolve(session: session, settings: settings) == nil {
                        debugLog("action=end-call dismissed because the call is gone")
                        markDismissed(session, reason: "call is gone")
                        try dismiss()
                    }
                }
            default:
                continue
            }
        }
    }

    private var nextRefreshNeeded = false
    private var responseLogCount = 0

    /// DynamicLake answers every frame we send. A frame it rejects must reach
    /// the log — otherwise a rejected payload looks exactly like an accepted
    /// one — while the stream of "ok" answers for animation frames is only
    /// worth its first few samples.
    @discardableResult
    private func logFrame(_ message: [String: Any]) -> Bool {
        let type = message["type"] as? String ?? "unknown"
        guard type != "action" else { return false }

        responseLogCount += 1
        let ok = message["ok"] as? Bool
        let error = (message["error"] as? String) ?? (message["message"] as? String)
        if ok == false || error != nil {
            debugLog("frame #\(responseLogCount) type=\(type) rejected error=\(error ?? "unknown")")
        } else if responseLogCount <= 3 {
            debugLog("frame #\(responseLogCount) type=\(type) ok")
        }
        return true
    }

    private func toggle(session: CallSession, control: String) -> Bool {
        if session.kind == "native", let pid = session.axPID {
            if pressNativeControl(pid: pid, control: control) {
                return true
            }
            debugLog("native \(control) press failed")
        }

        if session.kind == "web",
           let spec = browserSpecs.first(where: { $0.appName == session.appName }),
           let windowIndex = session.windowIndex,
           let tabIndex = session.tabIndex {
            guard let tab = enumerateWebTabs(spec: spec).first(where: { $0.windowIndex == windowIndex && $0.tabIndex == tabIndex && $0.url == session.url }) else { return false }
            let script = webJavaScript(webCallToggleJavaScript, control: control)
            let result = executeWebJavaScript(spec: spec, tab: tab, script: script)
            if actionSucceeded(result.output) {
                debugLog("web \(control) succeeded")
                return true
            }
            if safariJavaScriptBlocked(result.detail) {
                debugLog("web \(control) javascript blocked; enable \(safariJavaScriptHint)")
            } else {
                debugLog("web \(control) failed")
            }
        }

        if ["test", "diagnostic"].contains(session.kind) {
            return true
        }

        return false
    }

    /// Leaves the call. Fake sessions have nothing to leave, so they count as
    /// successfully ended and the caller hides them.
    private func end(session: CallSession) -> Bool {
        if ["test", "diagnostic"].contains(session.kind) {
            return true
        }
        return toggle(session: session, control: "end")
    }

    private func actionSucceeded(_ output: String?) -> Bool {
        guard let output else { return false }
        return output.hasPrefix("clicked")
    }

    /// Re-resolves a session by key: used after a failed action to decide
    /// whether the call itself disappeared.
    private func resolve(session: CallSession, settings: PluginSettings) -> CallSession? {
        refreshSession(settings: settings).first { $0.key == session.key }
    }

    private func refreshSession(settings: PluginSettings) -> [CallSession] {
        if ProcessInfo.processInfo.environment[testSessionEnvironmentKey] == "1" {
            return [testSession()]
        }
        if settings.diagnosticActivity {
            return [diagnosticSession()]
        }

        if settings.detectNativeCalls, let native = detectNativeCall() {
            return [native]
        }

        guard settings.detectWebCalls else { return [] }
        let web = webSessions(settings: settings, preferredAppName: currentSession?.appName)
        let issues = web.issues.joined(separator: "\n")
        if issues != lastIssues {
            lastIssues = issues
            if !issues.isEmpty {
                debugLog("web detection status changed (\(web.sessions.count) sessions, \(web.issues.count) diagnostic entries)")
            }
        }
        return web.sessions
    }

    /// Hides the activity and remembers *what* was hidden, so that a slow
    /// window close or a leftover fallback tab cannot publish it again.
    private func markDismissed(_ session: CallSession, reason: String) {
        dismissedToken = sessionToken(session)
        dismissedWasStateless = isStatelessSession(session)
        hiddenStatelessToken = nil
        dismissedMissingSince = nil
        armLeftoverWatch()
        debugLog("hidden: \(reason) kind=\(session.kind)")
    }

    /// Starts watching for the URL-only tab a finished call tends to leave
    /// behind. Bounded, so that a genuine browser call starting later is not
    /// mistaken for leftovers of this one.
    private func armLeftoverWatch() {
        statelessArmedUntil = Date().addingTimeInterval(leftoverWatchSeconds)
    }

    private func forgetDismissal() {
        dismissedToken = nil
        dismissedWasStateless = false
        hiddenStatelessToken = nil
        dismissedMissingSince = nil
        statelessArmedUntil = nil
    }

    /// True while this session must stay hidden.
    private func shouldStayHidden(_ session: CallSession) -> Bool {
        if let missingSince = dismissedMissingSince {
            let required = dismissedWasStateless || hiddenStatelessToken != nil ? statelessQuietSeconds : quietForgetSeconds
            if Date().timeIntervalSince(missingSince) >= required { forgetDismissal() }
        }
        dismissedMissingSince = nil
        let token = sessionToken(session)

        // A tab that only looks like a call because of its URL. While a call is
        // being hidden, or has just ended, such a tab is that call's leftover —
        // and it stays hidden until the tab moves on to something else.
        if isStatelessSession(session) {
            if let hidden = hiddenStatelessToken {
                if token == hidden { return true }
                // The tab now points somewhere else: it may be a real call.
                hiddenStatelessToken = nil
                statelessArmedUntil = nil
                return false
            }
            if statelessArmedUntil.map({ Date() < $0 }) == true {
                hiddenStatelessToken = token
                debugLog("hiding URL-only leftover")
                return true
            }
            return false
        }

        guard let dismissed = dismissedToken else { return false }
        guard token == dismissed else {
            // A different, fully known call: nothing to hide any more.
            forgetDismissal()
            return false
        }

        // Keep the same dismissed call hidden until detection observes a quiet gap.
        return true
    }

    private func refresh(settings: PluginSettings) throws {
        let sessions = refreshSession(settings: settings)
        let previous = currentSession

        // A call whose state we could actually read has just ended. Anything a
        // URL-only tab claims in the next moments belongs to that call, not to
        // a new one — this is what kept the activity alive after hanging up.
        if let previous, !isStatelessSession(previous), statelessArmedUntil == nil {
            let replaced = sessions.first.map { $0.key != previous.key || isStatelessSession($0) } ?? true
            if replaced {
                armLeftoverWatch()
                debugLog("known call gone; watching for the tab it leaves behind")
            }
        }

        if let nextSession = sessions.first {
            if let currentSession, currentSession.key == nextSession.key {
                nextSession.startedAt = currentSession.startedAt
            }

            if shouldStayHidden(nextSession) {
                currentSession = nil
                try dismiss()
                return
            }

            currentSession = nextSession
            if !isStatelessSession(nextSession) {
                // A real call is on screen again, leftovers no longer apply.
                statelessArmedUntil = nil
            }
            if settings.displaysWaveform, let pid = waveformTargetPID(for: nextSession) {
                meter.ensureRunning(targetPID: pid, micWanted: nextSession.micMuted == false, tapWanted: settings.captureAppAudio)
            } else {
                meter.stop()
            }
            try publish(session: nextSession, settings: settings)
            return
        }

        // No call at all. Forget the hiding once the silence is longer than the
        // flapping it protects against: one quiet poll for a known call (the
        // window really closed), a full minute for URL-only detection, which
        // drops out and comes back every couple of seconds.
        if dismissedToken != nil || hiddenStatelessToken != nil {
            if dismissedMissingSince == nil { dismissedMissingSince = Date() }
            let gap = Date().timeIntervalSince(dismissedMissingSince ?? Date())
            let longQuietNeeded = dismissedWasStateless || hiddenStatelessToken != nil
            if gap >= (longQuietNeeded ? statelessQuietSeconds : quietForgetSeconds) {
                forgetDismissal()
            }
        } else {
            dismissedMissingSince = nil
        }
        try dismiss()
    }

    private func publish(session: CallSession, settings: PluginSettings) throws {
        let signature = [
            session.key,
            session.title,
            session.browserName,
            session.detail,
            session.micMuted.map(String.init) ?? "unknown",
            session.cameraOn.map(String.init) ?? "unknown",
            String(settings.showWaveform),
            String(settings.captureAppAudio),
            settings.compactPresentation
        ].joined(separator: "|")

        guard signature != lastSignature else { return }

        let commandType = published ? "update" : "create"
        let waveform = waveformPNG(muted: !["test", "diagnostic"].contains(session.kind) && session.micMuted != false, enabled: settings.displaysWaveform, includeOther: settings.captureAppAudio || ["test", "diagnostic"].contains(session.kind))
        try client.send(activityPayload(
            commandType: commandType,
            session: session,
            waveform: waveform,
            showWaveform: settings.displaysWaveform
        ))
        debugLog("sent \(commandType) key=\(session.key) mic=\(session.micMuted.map(String.init) ?? "?") camera=\(session.cameraOn.map(String.init) ?? "?")")
        published = true
        lastSignature = signature
        // The tick keeps its own record of what is already on screen.
        lastWavePNG = waveform
        lastWaveElapsed = formatElapsed(Date().timeIntervalSince1970 - session.startedAt)
    }

    private func dismiss() throws {
        if published {
            try client.send(dismissPayload())
            debugLog("sent dismiss")
        }
        currentSession = nil
        published = false
        lastSignature = nil
        meter.stop()
        resetWaveHistory()
        lastWavePNG = nil
        lastWaveElapsed = ""
    }

    // MARK: Waveform

    static func lifecycleSelfTest() -> Bool {
        let plugin = WhatsAppCallPlugin(client: JSONSocketClient(socketPath: "/unused"))
        let session = testSession()
        plugin.markDismissed(session, reason: "self-test")
        session.micMuted = true
        session.cameraOn = false
        guard plugin.shouldStayHidden(session) else { return false }
        let next = CallSession(key: "next", kind: "native", title: "WhatsApp", url: nil, browserName: "WhatsApp", appName: "WhatsApp", startedAt: 0, micMuted: false, cameraOn: false)
        guard !plugin.shouldStayHidden(next) else { return false }
        let fallback = CallSession(key: "web:1", kind: "web", title: "WhatsApp", url: "https://web.whatsapp.com/call/1", browserName: "Test", appName: "Test", startedAt: 0)
        plugin.armLeftoverWatch()
        guard plugin.shouldStayHidden(fallback) else { return false }
        fallback.micMuted = false
        guard !plugin.shouldStayHidden(fallback) else { return false }
        next.micMuted = nil
        next.cameraOn = nil
        guard !isStatelessSession(next) else { return false }
        plugin.markDismissed(next, reason: "self-test")
        plugin.dismissedMissingSince = Date().addingTimeInterval(-4)
        return !plugin.shouldStayHidden(next)
    }

    private func padHistories() {
        while youHistory.count < waveformBarsPerSide { youHistory.insert(0, at: 0) }
        while themHistory.count < waveformBarsPerSide { themHistory.insert(0, at: 0) }
    }

    private func resetWaveHistory() {
        cachedWaveformKey = nil
        cachedWaveformPNG = nil
        youHistory = Array(repeating: 0, count: waveformBarsPerSide)
        themHistory = Array(repeating: 0, count: waveformBarsPerSide)
    }

    private func waveformPNG(muted: Bool, enabled: Bool, includeOther: Bool) -> Data? {
        guard enabled else { return nil }
        padHistories()
        let key = "\(muted):\(includeOther):\(youHistory):\(includeOther ? themHistory : [])"
        if key == cachedWaveformKey { return cachedWaveformPNG }
        cachedWaveformKey = key
        cachedWaveformPNG = renderWaveformPNG(you: youHistory, them: includeOther ? themHistory : Array(repeating: 0, count: waveformBarsPerSide), youMuted: muted)
        return cachedWaveformPNG
    }

    /// One frame: append the newest levels, redraw, and send the compact
    /// surface only when the bars or the duration actually changed — a silent
    /// call then costs one frame per second instead of eight.
    private func waveformTick(session: CallSession, settings: PluginSettings) throws {
        if !settings.displaysWaveform {
            let elapsed = formatElapsed(Date().timeIntervalSince1970 - session.startedAt)
            guard elapsed != lastWaveElapsed else { return }
            try client.send(compactUpdatePayload(session: session, waveform: nil, showWaveform: false))
            lastWaveElapsed = elapsed
            return
        }
        let snapshot = meter.snapshot

        padHistories()
        let preview = ["test", "diagnostic"].contains(session.kind)
        let phase = Float(ProcessInfo.processInfo.systemUptime * 5)
        youHistory.append(preview ? (sin(phase) + 1) * 0.4 + 0.1 : normalizedLevel(snapshot.mic))
        themHistory.append(preview ? (sin(phase + 2) + 1) * 0.35 : normalizedLevel(snapshot.other))
        youHistory.removeFirst(max(0, youHistory.count - waveformBarsPerSide))
        themHistory.removeFirst(max(0, themHistory.count - waveformBarsPerSide))

        let waveform = waveformPNG(muted: !["test", "diagnostic"].contains(session.kind) && session.micMuted != false, enabled: settings.displaysWaveform, includeOther: settings.captureAppAudio || ["test", "diagnostic"].contains(session.kind))
        let elapsed = formatElapsed(Date().timeIntervalSince1970 - session.startedAt)
        guard waveform != lastWavePNG || elapsed != lastWaveElapsed else { return }

        lastWavePNG = waveform
        lastWaveElapsed = elapsed
        try client.send(compactUpdatePayload(
            session: session,
            waveform: waveform,
            showWaveform: settings.displaysWaveform
        ))

        waveTickCount += 1
        if waveTickCount == 1 {
            debugLog("waveform: first frame mic=\(yesNo(snapshot.micRunning)) tap=\(yesNo(snapshot.otherRunning))")
        }
    }
}

// MARK: - Adaptive monitoring

private func monitoringInterval(settings: PluginSettings, active: Bool, appRunning: Bool) -> TimeInterval {
    if active || settings.diagnosticActivity || ProcessInfo.processInfo.environment[testSessionEnvironmentKey] == "1" { return settings.pollSeconds }
    return appRunning ? 3 : 15
}

/// All callbacks run on the same run loop as detection. Bursts become one refresh.
private final class NativeWatcher {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pid: pid_t = 0
    private var tokens: [NSObjectProtocol] = []
    private var nextAttachAt = Date.distantPast
    private var lastEventAt = Date.distantPast
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.nextAttachAt = .distantPast
                self?.changed()
            })
        }
    }

    deinit {
        detach()
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        application = nil
        pid = 0
    }

    func update(enabled: Bool) {
        guard enabled else { detach(); return }
        guard Date() >= nextAttachAt else { return }
        nextAttachAt = Date().addingTimeInterval(5)
        let nextPID = whatsappApplication()?.processIdentifier ?? 0
        if nextPID == pid, observer != nil { return }
        detach()
        guard nextPID != 0, AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(nextPID, { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<NativeWatcher>.fromOpaque(context).takeUnretainedValue()
            if Date().timeIntervalSince(watcher.lastEventAt) > 0.2 {
                watcher.lastEventAt = Date()
                watcher.changed()
            }
        }, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(nextPID)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification, kAXTitleChangedNotification] {
            _ = AXObserverAddNotification(created, app, notification as CFString, context)
        }
        observer = created
        application = app
        pid = nextPID
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
    }
}

private func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ value: Bool, _ name: String) {
        if !value { failures += 1; fputs("FAIL: \(name)\n", stderr) }
    }
    check(!microphoneCaptureAllowed(.notDetermined) && !microphoneCaptureAllowed(.denied) && !microphoneCaptureAllowed(.restricted), "no permission prompts")
    check(microphoneCaptureAllowed(.authorized), "reuse granted microphone permission")
    check(!PluginSettings().captureAppAudio, "system audio capture opt-in")
    check(normalizedLevel(0) == 0 && normalizedLevel(0.1) > 0.7, "audio amplitude drives waveform")
    check(doubleValue("nan", default: 1, minimum: 0.5, maximum: 5) == 1, "non-finite setting")
    check(doubleValue(99, default: 1, minimum: 0.5, maximum: 5) == 5, "setting clamp")
    check(isWebCallURL("https://web.whatsapp.com/call/123"), "call URL")
    for url in ["https://evil.test/web.whatsapp.com/call/123", "https://web.whatsapp.com.evil.test/call/123", "http://web.whatsapp.com/call/123", "https://web.whatsapp.com/"] {
        check(!isWebCallURL(url), "reject unrelated URL")
    }
    let settings = PluginSettings()
    check(monitoringInterval(settings: settings, active: false, appRunning: false) == 15, "closed cadence")
    check(monitoringInterval(settings: settings, active: false, appRunning: true) == 3, "idle cadence")
    check(monitoringInterval(settings: settings, active: true, appRunning: true) == 1, "active cadence")
    check(parseWebState("1|muted|off|test")?.micMuted == true, "web parsing")
    check(parseWebState("garbage") == nil, "malformed web state")
    if let png = renderWaveformPNG(you: Array(repeating: 1, count: 7), them: Array(repeating: 1, count: 7), youMuted: false),
       let bitmap = NSBitmapImageRep(data: png),
       let farEnd = bitmap.colorAt(x: 4, y: 28)?.usingColorSpace(.deviceRGB),
       let local = bitmap.colorAt(x: 196, y: 28)?.usingColorSpace(.deviceRGB) {
        check(farEnd.greenComponent > farEnd.redComponent, "far end green on left")
        check(local.redComponent > local.greenComponent, "local mic orange on right")
    } else { check(false, "waveform rendered color samples") }
    let compact = compactSurface(session: testSession(), waveform: nil, showWaveform: false)
    check((compact["leftSlot"] as? [String: Any])?["systemImage"] as? String == "phone.fill", "phone on left")
    check((compact["rightSlot"] as? [String: Any])?["type"] as? String == "text", "native elapsed text on right")
    check(!PluginSettings().displaysWaveform, "compact time is default")
    check(formatElapsed(125) == "2:05", "elapsed time")
    check(waveformTargetPID(for: testSession()) == nil, "test never captures real audio")
    check(waveformTargetPID(for: diagnosticSession()) == nil, "preview never captures real audio")
    check(WhatsAppCallPlugin.lifecycleSelfTest(), "dismissal and next-call lifecycle")
    print(failures == 0 ? "All self-tests passed" : "\(failures) self-tests failed")
    return failures == 0 ? 0 : 1
}

// MARK: - Output helpers

private func printJSON(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

private func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
}

private func stateLabel(_ value: Bool?) -> String {
    switch value {
    case .some(true): return "on"
    case .some(false): return "off"
    case nil: return "unknown"
    }
}

private func runCheck() -> Int32 {
    let settings = loadSettings()
    let labels = loadCallLabels()

    print("Plugin: \(pluginName)")
    print("Runtime: Swift")
    print("Socket path: \(ProcessInfo.processInfo.environment[socketEnvironmentKey] ?? "missing")")
    print("Settings: \(settings)")
    print("Debug log: \(debugLogPath().path)")
    print("Control labels: \(labelSource)")
    print("Accessibility trusted: \(yesNo(AXIsProcessTrusted()))")
    print("WhatsApp running: \(yesNo(whatsappApplication() != nil))")
    print("osascript: \(FileManager.default.fileExists(atPath: "/usr/bin/osascript") ? "ok" : "missing")")

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        print("Microphone: authorized (your side of the waveform is live)")
    case .denied, .restricted:
        print("Microphone: denied — your side of the waveform stays flat")
    case .notDetermined:
        print("Microphone: not authorized — capture skipped without prompting")
    @unknown default:
        print("Microphone: unknown status")
    }
    print("Waveform: \(settings.showWaveform ? "on, one frame every \(Int(waveformInterval * 1000)) ms" : "disabled in settings")")
    if let outputUID = defaultOutputDeviceUID() {
        print("  your voice: microphone RMS")
        print("  their voice: process tap of the call app's output on \(outputUID)")
    } else {
        print("  default output device unreadable, their side of the waveform will stay flat")
    }

    if settings.detectNativeCalls, AXIsProcessTrusted(), let application = whatsappApplication() {
        let started = Date()
        if let state = nativeCallState() {
            print("Native call: detected (\(state.windowTitle)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            print("  microphone: \(state.micMuted == true ? "muted" : state.micMuted == false ? "live" : "unknown")")
            print("  camera: \(state.cameraOn == true ? "on" : state.cameraOn == false ? "off" : "unknown")")
            print("  leave button: \(state.hasLeaveButton ? "found (the end-call control can press it)" : "not visible right now")")
        } else {
            print("Native call: none (process \(application.processIdentifier))")
        }
        let english = fallbackLabels()
        print("  microphone labels: \(labels.muted.count + labels.live.count) descriptions across the loaded translations, English: \(Array(english.muted.union(english.live)).sorted().joined(separator: ", "))")
        print("  camera labels: \(labels.cameraOn.count + labels.cameraOff.count) descriptions across the loaded translations, English: \(Array(english.cameraOn.union(english.cameraOff)).sorted().joined(separator: ", "))")
        print("  leave-call labels: \(labels.leaveCall.count) descriptions across the loaded translations, English: \(Array(english.leaveCall).sorted().joined(separator: ", "))")
    } else if settings.detectNativeCalls {
        print("Native call: skipped (needs Accessibility trust and a running WhatsApp)")
    } else {
        print("Native call: detection disabled in settings")
    }

    if !settings.detectWebCalls {
        print("Web calls: detection disabled in settings")
        print("JavaScript from Apple Events needed for web controls:")
        print("  \(safariJavaScriptHint)")
        print("  \(chromeJavaScriptHint)")
        return 0
    }

    let runningBrowsers = browserSpecs.filter { appIsRunning($0.appName) }
    print("Browsers: \(runningBrowsers.isEmpty ? "none running" : runningBrowsers.map(\.displayName).joined(separator: ", "))")
    print("JavaScript from Apple Events needed for web controls:")
    print("  \(safariJavaScriptHint)")
    print("  \(chromeJavaScriptHint)")

    var found = false
    for spec in runningBrowsers {
        guard detectionAllowed(for: spec.appName) else {
            print("- \(spec.displayName): backing off after earlier failures")
            continue
        }

        let tabs = enumerateWebTabs(spec: spec)
        if tabs.isEmpty {
            print("- \(spec.displayName): no web.whatsapp.com tabs")
            continue
        }

        for tab in tabs {
            let result = executeWebJavaScript(spec: spec, tab: tab, script: stateJavaScript())
            found = true
            print("- \(spec.displayName) window \(tab.windowIndex) tab \(tab.tabIndex): \(tab.url)")
            if let output = result.output, let state = parseWebState(output) {
                print("    call: \(state.active ? "ACTIVE" : "not active")")
                print("    microphone: \(state.micMuted == true ? "muted" : state.micMuted == false ? "live" : "unknown")")
                print("    camera: \(state.cameraOn == true ? "on" : state.cameraOn == false ? "off" : "unknown")")
                print("    controls: \(state.detail)")
            } else {
                print("    JavaScript unavailable (\(result.detail ?? "no result"))")
                if isWebCallURL(tab.url) {
                    print(settings.webUrlFallback
                        ? "    fallback: in-call URL detected, so the activity would show with unknown states"
                        : "    fallback: in-call URL detected, but \"Fallback Without JavaScript\" is disabled in settings")
                }
            }
        }
    }

    if !found {
        print("Web sessions: none detected")
    }
    return 0
}

private func runDemoJSON() -> Int32 {
    let now = Date().timeIntervalSince1970
    let sample = CallSession(
        key: "native",
        kind: "native",
        title: "WhatsApp",
        url: nil,
        browserName: "WhatsApp",
        appName: "WhatsApp",
        startedAt: now - 44,
        micMuted: false,
        cameraOn: true
    )
    sample.detail = "Group video call"

    // Simulated sample: green far end, orange local microphone.
    let demoYou: [Float] = [0.15, 0.4, 0.75, 0.9, 0.6, 0.35, 0.2]
    let demoThem: [Float] = [0.7, 0.85, 0.55, 0.3, 0.2, 0.15, 0.1]
    printJSON(activityPayload(
        commandType: "create",
        session: sample,
        waveform: renderWaveformPNG(you: demoYou, them: demoThem, youMuted: false),
        showWaveform: loadSettings().displaysWaveform
    ))
    return 0
}

@main
private enum Main {
    static func main() {
        let arguments = Set(CommandLine.arguments.dropFirst())

        if arguments.contains("--audio-check") { exit(runAudioCheck()) }

        if arguments.contains("--self-test") { exit(runSelfTest()) }

        if arguments.contains("--check") {
            exit(runCheck())
        }

        if arguments.contains("--demo-json") {
            exit(runDemoJSON())
        }

        guard let socketPath = ProcessInfo.processInfo.environment[socketEnvironmentKey],
              !socketPath.isEmpty else {
            fputs("\(pluginName): \(PluginError.socketPathMissing)\n", stderr)
            exit(64)
        }

        do {
            let client = JSONSocketClient(socketPath: socketPath)
            try WhatsAppCallPlugin(client: client).run()
        } catch {
            fputs("\(pluginName): \(error)\n", stderr)
            debugLog("fatal \(error)")
            exit(65)
        }
    }
}
