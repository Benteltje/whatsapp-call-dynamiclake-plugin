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
private let testSessionEnvironmentKey = "DYNAMICLAKE_WHATSAPP_CALL_TEST_SESSION"
private let maxFrameSize = 64 * 1024
private let timerMaximumDuration: TimeInterval = 48 * 60 * 60
private let actionLoopInterval: TimeInterval = 0.05
private let verboseAudioDiagnostics = ProcessInfo.processInfo.environment["DYNAMICLAKE_WHATSAPP_DEBUG"] == "1"

/// Cadence of the waveform animation: fast enough to read as movement, slow
/// enough that the inline PNG frames stay cheap on the local socket.
private let waveformInterval: TimeInterval = 0.12
/// Bars per side — your microphone on the left in orange, the far end on the right in green.
private let waveformBarsPerSide = 7
private let waveformWidth = 100
private let waveformHeight = 28
/// No mic buffer for this long means the engine was interrupted (another app
/// took the input) rather than the room going quiet.
private let micStaleSeconds: TimeInterval = 0.5

/// The widest compact geometry: a 351 x 33 pt panel with 77 pt side slots, which
/// provides room for the phone icon and the waveform together.
private let activitySize = "normal"

/// Silence required before a dismissal of a known call is forgotten, so the
/// next call in the same app shows again. One quiet poll is already a closed
/// window; the small margin absorbs a single failed detection.
private let quietForgetSeconds: TimeInterval = 3
/// AXIdentifier of the group WhatsApp mounts in its call window. Identifiers are
/// not localized, which is why detection uses it instead of the window title.
private let callWindowIdentifier = "Calling_Window"
private let whatsappBundleIdentifier = "net.whatsapp.WhatsApp"

// MARK: - Settings

private struct PluginSettings: Equatable, CustomStringConvertible {
    var pollSeconds: TimeInterval = 1
    var detectNativeCalls = true
    var diagnosticActivity = false
    var showWaveform = true
    var captureAppAudio = false

    var description: String {
        "PluginSettings(pollSeconds: \(pollSeconds), detectNativeCalls: \(detectNativeCalls), diagnosticActivity: \(diagnosticActivity), showWaveform: \(showWaveform), captureAppAudio: \(captureAppAudio))"
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
        diagnosticActivity: boolValue(settingValue(values, id: "diagnosticActivity", default: false), default: false),
        showWaveform: boolValue(settingValue(values, id: "showWaveform", default: true), default: true),
        captureAppAudio: boolValue(settingValue(values, id: "captureAppAudio", default: false), default: false)
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
///   pointed at WhatsApp, so music in another app
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
    private var micLastBufferAt = Date.distantPast
    private var micLastRestartAt = Date.distantPast
    private var tapLastAttempt = Date.distantPast

    struct Snapshot {
        let mic: Float
        let other: Float
        let micRunning: Bool
        let micStale: Bool
        let micFrames: Int
        let otherRunning: Bool
    }

    var snapshot: Snapshot {
        lock.lock()
        let mic = micLevel
        let micOn = micRunning
        let micCount = micFrames
        let micAt = micLastBufferAt
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

        let fresh = micOn && Date().timeIntervalSince(micAt) < micStaleSeconds
        return Snapshot(mic: fresh ? mic : 0, other: other, micRunning: micOn, micStale: micOn && !fresh, micFrames: micCount, otherRunning: frames > 0)
    }

    /// True when the engine claims to run but no buffer has arrived recently.
    private var micInputStalled: Bool {
        lock.lock()
        let stalled = engine != nil && Date().timeIntervalSince(micLastBufferAt) >= micStaleSeconds
        lock.unlock()
        return stalled
    }

    /// Opens whatever is missing. The microphone belongs to this process rather
    /// than to the call, so it stays open across native state refreshes.
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
                if engine == nil { micLastAttempt = Date().addingTimeInterval(2) }
                lock.unlock()
            } else if micOpen, micInputStalled, Date().timeIntervalSince(micLastRestartAt) >= 3 {
                // The engine object is alive but no buffers arrive: another app
                // took the input, or the device changed underneath us. Restart
                // it instead of freezing on the last value forever.
                debugLog("waveform: input stalled; restarting microphone")
                lock.lock()
                micLastRestartAt = Date()
                lock.unlock()
                stopMicrophone()
                startMicrophone()
                lock.lock()
                if engine == nil { micLastAttempt = Date().addingTimeInterval(2) }
                lock.unlock()
            }
        } else if micOpen {
            // Muted, or state unknown: the orange side is drawn flat anyway, so
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
                self.micLastBufferAt = Date()
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
        debugLog("waveform: microphone meter running device=\(inputDeviceName())")
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

/// Name of the default input device, for the debug log: if a call switches the
/// mic to another device, the waveform values change with it.
private func inputDeviceName() -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
          deviceID != kAudioObjectUnknown else { return "?" }
    var name: CFString = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.stride)
    var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return "?" }
    return name as String
}

/// Compress the dynamic range so quiet speech remains visible after louder
/// words. Gate actual silence before applying gain; never amplify zero input.
private func scaledLevel(_ level: Float, peak: Float) -> Float {
    let silenceFloor: Float = 0.0001 // −80 dBFS, for low-gain microphones
    guard level.isFinite, peak.isFinite, level > silenceFloor else { return 0 }
    let relative = level / max(peak, silenceFloor)
    return min(sqrt(max(relative, 0)) * 1.15, 1)
}

/// Limit transient attacks and recover from loud words in a few seconds.
private func updatedPeak(_ peak: Float, _ level: Float) -> Float {
    let silenceFloor: Float = 0.0001
    if peak < silenceFloor { return level }
    if level > peak { return min(level, peak * 4) }
    return max(silenceFloor, peak * 0.96)
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

    // Your microphone leads in orange; the remote participants follow in green.
    for (index, value) in you.enumerated() {
        draw(index, youMuted ? 0 : value, youMuted ? gray : orange)
    }
    for (index, value) in them.enumerated() {
        draw(you.count + index, value, green)
    }

    guard let image = context.makeImage() else { return nil }
    return pngData(from: image)
}

/// Synthetic sessions never open audio capture.
private func waveformTargetPID(for session: CallSession) -> pid_t? {
    session.kind == "native" ? session.axPID : nil
}

// MARK: - Sessions

private final class CallSession {
    let key: String
    let kind: String
    let title: String
    /// Present for native sessions; the AX element itself is re-resolved per action.
    let axPID: pid_t?
    var startedAt: TimeInterval
    var micMuted: Bool?
    var cameraOn: Bool?
    /// Free-form native call state used by `--check`.
    var detail: String = ""

    init(
        key: String,
        kind: String,
        title: String,
        axPID: pid_t? = nil,
        startedAt: TimeInterval,
        micMuted: Bool? = nil,
        cameraOn: Bool? = nil
    ) {
        self.key = key
        self.kind = kind
        self.title = title
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

// MARK: - Test sessions

private func testSession() -> CallSession {
    CallSession(
        key: "test:whatsapp-call",
        kind: "test",
        title: "WhatsApp",
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

/// ImageIO writes a PNG out of whatever the compact slots are given.
private func pngData(from image: CGImage?) -> Data? {
    guard let image else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private func phoneComponent(id: String) -> [String: Any] {
    ["type": "image", "id": id, "source": "sfSymbol", "systemImage": "phone.fill", "tint": "green"]
}

private func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

/// Compact right slot: the live green/orange waveform. Without a PNG (waveform
/// switched off, nothing rendered yet) the slot is simply left empty.
private func waveformComponent(id: String, png: Data?) -> [String: Any]? {
    guard let png else { return nil }
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

/// Compact surface: the tilted green phone symbol on the left, the live
/// waveform on the right.
private func compactSurface(session: CallSession, waveform: Data?, showWaveform: Bool) -> [String: Any] {
    var surface: [String: Any] = [
        "leftSlot": phoneComponent(id: "whatsapp-phone")
    ]
    if showWaveform, let wave = waveformComponent(id: "whatsapp-waveform", png: waveform) {
        surface["rightSlot"] = wave
    }
    return surface
}

/// Sent on every waveform tick. Only the compact surface is named, so the sneak
/// peek keeps its microphone, hang-up and camera controls untouched.
private func compactUpdatePayload(session: CallSession, waveform: Data?, showWaveform: Bool) -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "type": "update",
        "activityID": activityID,
        "size": activitySize,
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
        "size": activitySize,
        "surfaces": [
            "compactLiveActivity": compactSurface(session: session, waveform: waveform, showWaveform: showWaveform),
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
    /// Keep a dismissed call hidden until detection sees a quiet gap.
    private var dismissedToken: String?
    private var dismissedMissingSince: Date?
    private var lastSettings: PluginSettings?

    /// Voice activity for the compact waveform.
    private let meter = WaveformMeter()
    private var youHistory: [Float] = []
    private var themHistory: [Float] = []
    private var nextWaveAt = Date.distantPast
    private var cachedWaveformKey: String?
    private var cachedWaveformPNG: Data?
    private var lastWavePNG: Data?
    private var waveTickCount = 0
    private var micPeak: Float = 0
    private var otherPeak: Float = 0
    private var micRecent: [Float] = []
    private var waveDiagCount = 0

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
                watcher.update(enabled: settings.detectNativeCalls, active: currentSession != nil)
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
                    nextRefreshAt = Date().addingTimeInterval(monitoringInterval(settings: settings, active: currentSession != nil, appRunning: settings.detectNativeCalls && whatsappApplication() != nil))
                }

                // The waveform is the one thing that must keep moving between
                // polls: without it a call looks frozen for a full second at a time.
                if published, let session = currentSession, Date() >= nextWaveAt {
                    nextWaveAt = Date().addingTimeInterval(settings.showWaveform ? waveformInterval : 1.0)
                    try waveformTick(session: session, settings: settings)
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(published ? actionLoopInterval : 1.0))
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

        return []
    }

    private func markDismissed(_ session: CallSession, reason: String) {
        dismissedToken = session.key
        dismissedMissingSince = nil
        debugLog("hidden: \(reason) kind=\(session.kind)")
    }

    private func forgetDismissal() {
        dismissedToken = nil
        dismissedMissingSince = nil
    }

    private func shouldStayHidden(_ session: CallSession) -> Bool {
        if let missingSince = dismissedMissingSince,
           Date().timeIntervalSince(missingSince) >= quietForgetSeconds {
            forgetDismissal()
        }
        dismissedMissingSince = nil
        guard let dismissed = dismissedToken else { return false }
        guard session.key == dismissed else {
            forgetDismissal()
            return false
        }
        return true
    }

    private func refresh(settings: PluginSettings) throws {
        let sessions = refreshSession(settings: settings)
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
            if settings.showWaveform, let pid = waveformTargetPID(for: nextSession) {
                meter.ensureRunning(targetPID: pid, micWanted: nextSession.micMuted == false, tapWanted: settings.captureAppAudio)
            } else {
                meter.stop()
            }
            try publish(session: nextSession, settings: settings)
            return
        }

        if dismissedToken != nil {
            if dismissedMissingSince == nil { dismissedMissingSince = Date() }
            if Date().timeIntervalSince(dismissedMissingSince ?? Date()) >= quietForgetSeconds {
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
            session.detail,
            session.micMuted.map(String.init) ?? "unknown",
            session.cameraOn.map(String.init) ?? "unknown",
            String(settings.showWaveform),
            String(settings.captureAppAudio),
        ].joined(separator: "|")

        guard signature != lastSignature else { return }

        let commandType = published ? "update" : "create"
        let waveform = waveformPNG(muted: !["test", "diagnostic"].contains(session.kind) && session.micMuted != false, enabled: settings.showWaveform, includeOther: settings.captureAppAudio || ["test", "diagnostic"].contains(session.kind))
        try client.send(activityPayload(
            commandType: commandType,
            session: session,
            waveform: waveform,
            showWaveform: settings.showWaveform
        ))
        debugLog("sent \(commandType) key=\(session.key) mic=\(session.micMuted.map(String.init) ?? "?") camera=\(session.cameraOn.map(String.init) ?? "?")")
        published = true
        lastSignature = signature
        // The tick keeps its own record of what is already on screen.
        lastWavePNG = waveform
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
    }

    // MARK: Waveform

    static func lifecycleSelfTest() -> Bool {
        let plugin = WhatsAppCallPlugin(client: JSONSocketClient(socketPath: "/unused"))
        let session = testSession()
        plugin.markDismissed(session, reason: "self-test")
        session.micMuted = true
        session.cameraOn = false
        guard plugin.shouldStayHidden(session) else { return false }
        let next = CallSession(key: "next", kind: "native", title: "WhatsApp", startedAt: 0, micMuted: false, cameraOn: false)
        guard !plugin.shouldStayHidden(next) else { return false }
        next.micMuted = nil
        next.cameraOn = nil
        plugin.markDismissed(next, reason: "self-test")
        plugin.dismissedMissingSince = Date().addingTimeInterval(-4)
        return !plugin.shouldStayHidden(next)
    }

    private func padHistories() {
        while youHistory.count < waveformBarsPerSide { youHistory.insert(0, at: 0) }
        while themHistory.count < waveformBarsPerSide { themHistory.insert(0, at: 0) }
    }

    private func resetWaveHistory() {
        micPeak = 0
        otherPeak = 0
        micRecent.removeAll(keepingCapacity: true)
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
    /// surface only when the bars changed. Steady silence emits no frames.
    private func waveformTick(session: CallSession, settings: PluginSettings) throws {
        guard settings.showWaveform else { return }
        let snapshot = meter.snapshot

        padHistories()
        let preview = ["test", "diagnostic"].contains(session.kind)
        let phase = Float(ProcessInfo.processInfo.systemUptime * 5)
        if preview {
            youHistory.append((sin(phase) + 1) * 0.4 + 0.1)
            themHistory.append((sin(phase + 2) + 1) * 0.35)
        } else {
            // Median of the last three readings: speech sustains across
            // buffers, single-buffer device clicks do not.
            micRecent.append(snapshot.mic)
            if micRecent.count > 3 { micRecent.removeFirst() }
            let micSmoothed = micRecent.sorted(by: <)[micRecent.count / 2]
            micPeak = updatedPeak(micPeak, micSmoothed)
            otherPeak = updatedPeak(otherPeak, snapshot.other)
            let you = scaledLevel(micSmoothed, peak: micPeak)
            youHistory.append(you)
            themHistory.append(scaledLevel(snapshot.other, peak: otherPeak))

            waveDiagCount += 1
            if verboseAudioDiagnostics && waveDiagCount % 8 == 1 {
                debugLog(String(
                    format: "waveform: mic=%.5f (%.1f dB) peak=%.5f (%.1f dB) bar=%.2f frames=%d tap=%.5f stale=%d",
                    micSmoothed, 20 * log10(max(Double(micSmoothed), 1e-6)),
                    micPeak, 20 * log10(max(Double(micPeak), 1e-6)),
                    you, snapshot.micFrames, snapshot.other, snapshot.micStale ? 1 : 0))
            }
        }
        youHistory.removeFirst(max(0, youHistory.count - waveformBarsPerSide))
        themHistory.removeFirst(max(0, themHistory.count - waveformBarsPerSide))

        let waveform = waveformPNG(muted: !["test", "diagnostic"].contains(session.kind) && session.micMuted != false, enabled: settings.showWaveform, includeOther: settings.captureAppAudio || ["test", "diagnostic"].contains(session.kind))
        guard waveform != lastWavePNG else { return }

        lastWavePNG = waveform
        try client.send(compactUpdatePayload(
            session: session,
            waveform: waveform,
            showWaveform: settings.showWaveform
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
    private var active = false
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

    func update(enabled: Bool, active: Bool) {
        self.active = active
        guard enabled else { detach(); return }
        guard Date() >= nextAttachAt else { return }
        nextAttachAt = Date().addingTimeInterval(pid == 0 ? 15 : 5)
        let nextPID = whatsappApplication()?.processIdentifier ?? 0
        if nextPID == pid, observer != nil { return }
        detach()
        guard nextPID != 0, AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(nextPID, { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<NativeWatcher>.fromOpaque(context).takeUnretainedValue()
            if Date().timeIntervalSince(watcher.lastEventAt) > (watcher.active ? 0.2 : 0.75) {
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
    check(scaledLevel(0, peak: 0.1) == 0 && scaledLevel(0.1, peak: 0.1) == 1, "audio amplitude drives waveform")
    let midBar = scaledLevel(0.05, peak: 0.1)
    check(midBar > 0.8, "normal speech has a strong bar")
    check(scaledLevel(0.0005, peak: 0.002) > 0.55, "quiet low-gain speech stays visible")
    check(scaledLevel(0.00005, peak: 0.002) == 0, "silence stays flat")
    check(scaledLevel(0.002, peak: 0.1) > 0.15, "quiet speech remains visible after a loud word")
    check(abs(updatedPeak(0.01, 0.2) - 0.04) < 0.00001 && updatedPeak(0.2, 0.01) < 0.2, "peak attack and slow release")
    check(doubleValue("nan", default: 1, minimum: 0.5, maximum: 5) == 1, "non-finite setting")
    check(doubleValue(99, default: 1, minimum: 0.5, maximum: 5) == 5, "setting clamp")
    let settings = PluginSettings()
    check(monitoringInterval(settings: settings, active: false, appRunning: false) == 15, "closed cadence")
    check(monitoringInterval(settings: settings, active: false, appRunning: true) == 3, "idle cadence")
    check(monitoringInterval(settings: settings, active: true, appRunning: true) == 1, "active cadence")
    if let png = renderWaveformPNG(you: Array(repeating: 1, count: 7), them: Array(repeating: 1, count: 7), youMuted: false),
       let bitmap = NSBitmapImageRep(data: png),
       let yours = bitmap.colorAt(x: 4, y: 28)?.usingColorSpace(.deviceRGB),
       let theirs = bitmap.colorAt(x: 196, y: 28)?.usingColorSpace(.deviceRGB) {
        check(yours.redComponent > yours.greenComponent, "your microphone orange on the left")
        check(theirs.greenComponent > theirs.redComponent, "far end green on the right")
    } else { check(false, "waveform rendered color samples") }

    // The compact surface: the tilted phone symbol owns the left slot, the
    // waveform owns the right one.
    let quiet = compactSurface(session: testSession(), waveform: nil, showWaveform: false)
    let left = quiet["leftSlot"] as? [String: Any]
    check(left?["type"] as? String == "image" && left?["source"] as? String == "sfSymbol" && left?["systemImage"] as? String == "phone.fill", "tilted phone symbol in the left slot")
    check(quiet["rightSlot"] == nil, "no waveform when the waveform is switched off")

    let live = compactSurface(session: testSession(), waveform: renderWaveformPNG(you: Array(repeating: 0.5, count: 7), them: Array(repeating: 0.5, count: 7), youMuted: false), showWaveform: true)
    let wave = live["rightSlot"] as? [String: Any]
    check(wave?["type"] as? String == "image" && wave?["id"] as? String == "whatsapp-waveform", "waveform on the right")
    check(activitySize == "normal", "middle compact geometry")
    check(PluginSettings().showWaveform, "waveform is on by default")
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

    return 0
}

private func runDemoJSON() -> Int32 {
    let now = Date().timeIntervalSince1970
    let sample = CallSession(
        key: "native",
        kind: "native",
        title: "WhatsApp",
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
        showWaveform: loadSettings().showWaveform
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
