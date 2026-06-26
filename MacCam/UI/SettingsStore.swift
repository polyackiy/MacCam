import Foundation
import Combine

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC (H.265)" : "H.264" }
}

/// Menu-bar appearance. `.normal` shows status colors (gray/green/red-blink);
/// `.discreet` shows a single neutral monochrome glyph in every state so an
/// onlooker can't tell monitoring or recording is active.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case normal, discreet
    var id: String { rawValue }
    var label: String {
        self == .normal ? "Normal (status colors)" : "Discreet (neutral)"
    }
}

/// Glyph used in discreet mode. A mix of neutral icons (not associated with
/// cameras/recording) and a couple of recognizable ones, user's choice.
enum DiscreetIcon: String, CaseIterable, Identifiable {
    case circle, dot, moon, gear, bolt, cloud, sparkles, leaf, eye, camera
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .circle: return "circle"
        case .dot: return "circle.fill"
        case .moon: return "moon"
        case .gear: return "gearshape"
        case .bolt: return "bolt"
        case .cloud: return "cloud"
        case .sparkles: return "sparkles"
        case .leaf: return "leaf"
        case .eye: return "eye"
        case .camera: return "video"
        }
    }
    var label: String {
        switch self {
        case .circle: return "Circle"
        case .dot: return "Dot"
        case .moon: return "Moon"
        case .gear: return "Gear"
        case .bolt: return "Bolt"
        case .cloud: return "Cloud"
        case .sparkles: return "Sparkles"
        case .leaf: return "Leaf"
        case .eye: return "Eye"
        case .camera: return "Camera"
        }
    }
}

/// Immutable snapshot of all settings, read atomically on the capture queue so
/// UI edits never tear a frame's worth of configuration.
enum DiskLimitPolicy: String, CaseIterable, Identifiable {
    case loop, stop
    var id: String { rawValue }
    var label: String { self == .loop ? "Loop (delete oldest)" : "Stop & notify" }
}

struct AppSettings: Equatable {
    var cameraID: String?
    var targetFPS: Int
    var sensitivity: Int
    var pixelDelta: Int
    var postMotionCooldown: Double
    var minClipLength: Double
    var maxClipLength: Double
    var preRollEnabled: Bool
    var preRoll: Double
    var audioEnabled: Bool
    var audioDeviceID: String?
    var triggerMode: TriggerMode
    var voiceSensitivity: Int
    var audioOnly: Bool
    var codec: VideoCodec
    var quality: Quality
    var autoCleanup: Bool
    var cleanupDays: Int
    var guardMode: Bool
    var monitoringSchedule: WeeklySchedule
    var recordingSchedule: WeeklySchedule
    var maxStorageGB: Double
    var minFreeSpaceGB: Double
    var diskLimitPolicy: DiskLimitPolicy
    var detectionMask: String

    var motionThreshold: Double { MotionMath.motionThreshold(forSensitivity: sensitivity) }

    /// Audio-only is effective only when audio is on and the trigger permits it
    /// (Continuous or Voice). A stale `audioOnly` in any other combination is
    /// inert, so the camera/recorder never silently drop video.
    var effectiveAudioOnly: Bool { audioOnly && audioEnabled && triggerMode.allowsAudioOnly }
}

/// `UserDefaults`-backed, observable settings. `@Published` properties persist
/// on write; `snapshot()` produces a value type for the capture pipeline.
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private enum Key {
        static let cameraID = "cameraID"
        static let targetFPS = "targetFPS"
        static let sensitivity = "sensitivity"
        static let pixelDelta = "pixelDelta"
        static let cooldown = "postMotionCooldown"
        static let minClip = "minClipLength"
        static let maxClip = "maxClipLength"
        static let preRollEnabled = "preRollEnabled"
        static let preRoll = "preRoll"
        static let audioEnabled = "audioEnabled"
        static let audioDeviceID = "audioDeviceID"
        static let triggerMode = "triggerMode"
        static let audioOnly = "audioOnly"
        static let voiceSensitivity = "voiceSensitivity"
        static let codec = "codec"
        static let quality = "quality"
        static let autoCleanup = "autoCleanup"
        static let cleanupDays = "cleanupDays"
        static let guardMode = "guardMode"
        static let launchAtLogin = "launchAtLogin"
        static let menuBarStyle = "menuBarStyle"
        static let discreetIcon = "discreetIcon"
        static let maxStorageGB = "maxStorageGB"
        static let minFreeSpaceGB = "minFreeSpaceGB"
        static let diskLimitPolicy = "diskLimitPolicy"
        static let detectionMask = "detectionMask"
        static let monitoringSchedule = "monitoringSchedule"
        static let recordingSchedule = "recordingSchedule"
    }

    private static func encodeSchedule(_ schedule: WeeklySchedule) -> String {
        guard let data = try? JSONEncoder().encode(schedule),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func decodeSchedule(_ string: String?) -> WeeklySchedule {
        guard let string, let data = string.data(using: .utf8),
              let schedule = try? JSONDecoder().decode(WeeklySchedule.self, from: data) else {
            return WeeklySchedule()
        }
        return schedule
    }

    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: Key.cameraID) } }
    @Published var targetFPS: Int { didSet { defaults.set(targetFPS, forKey: Key.targetFPS) } }
    @Published var sensitivity: Int { didSet { defaults.set(sensitivity, forKey: Key.sensitivity) } }
    @Published var pixelDelta: Int { didSet { defaults.set(pixelDelta, forKey: Key.pixelDelta) } }
    @Published var postMotionCooldown: Double { didSet { defaults.set(postMotionCooldown, forKey: Key.cooldown) } }
    @Published var minClipLength: Double { didSet { defaults.set(minClipLength, forKey: Key.minClip) } }
    @Published var maxClipLength: Double { didSet { defaults.set(maxClipLength, forKey: Key.maxClip) } }
    @Published var preRollEnabled: Bool { didSet { defaults.set(preRollEnabled, forKey: Key.preRollEnabled) } }
    @Published var preRoll: Double { didSet { defaults.set(preRoll, forKey: Key.preRoll) } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: Key.audioEnabled) } }
    @Published var audioDeviceID: String? { didSet { defaults.set(audioDeviceID, forKey: Key.audioDeviceID) } }
    @Published var triggerMode: TriggerMode { didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode) } }
    @Published var audioOnly: Bool { didSet { defaults.set(audioOnly, forKey: Key.audioOnly) } }
    @Published var voiceSensitivity: Int { didSet { defaults.set(voiceSensitivity, forKey: Key.voiceSensitivity) } }
    @Published var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: Key.quality) } }
    @Published var autoCleanup: Bool { didSet { defaults.set(autoCleanup, forKey: Key.autoCleanup) } }
    @Published var cleanupDays: Int { didSet { defaults.set(cleanupDays, forKey: Key.cleanupDays) } }
    @Published var guardMode: Bool { didSet { defaults.set(guardMode, forKey: Key.guardMode) } }
    @Published var monitoringSchedule: WeeklySchedule {
        didSet { defaults.set(Self.encodeSchedule(monitoringSchedule), forKey: Key.monitoringSchedule) }
    }
    @Published var recordingSchedule: WeeklySchedule {
        didSet { defaults.set(Self.encodeSchedule(recordingSchedule), forKey: Key.recordingSchedule) }
    }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) } }
    @Published var discreetIcon: DiscreetIcon { didSet { defaults.set(discreetIcon.rawValue, forKey: Key.discreetIcon) } }
    @Published var maxStorageGB: Double { didSet { defaults.set(maxStorageGB, forKey: Key.maxStorageGB) } }
    @Published var minFreeSpaceGB: Double { didSet { defaults.set(minFreeSpaceGB, forKey: Key.minFreeSpaceGB) } }
    @Published var diskLimitPolicy: DiskLimitPolicy { didSet { defaults.set(diskLimitPolicy.rawValue, forKey: Key.diskLimitPolicy) } }
    @Published var detectionMask: String { didSet { defaults.set(detectionMask, forKey: Key.detectionMask) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.targetFPS: 30,
            Key.sensitivity: 2,
            Key.pixelDelta: 25,
            Key.cooldown: 5.0,
            Key.minClip: 5.0,
            Key.maxClip: 60.0,
            Key.preRollEnabled: false,
            Key.preRoll: 3.0,
            Key.audioEnabled: false,
            Key.triggerMode: TriggerMode.motion.rawValue,
            Key.audioOnly: false,
            Key.voiceSensitivity: 2,
            Key.codec: VideoCodec.hevc.rawValue,
            Key.quality: Quality.medium.rawValue,
            Key.autoCleanup: false,
            Key.cleanupDays: 14,
            Key.guardMode: false,
            Key.launchAtLogin: false,
            Key.menuBarStyle: MenuBarStyle.normal.rawValue,
            Key.discreetIcon: DiscreetIcon.circle.rawValue,
            Key.maxStorageGB: 0.0,
            Key.minFreeSpaceGB: 0.0,
            Key.diskLimitPolicy: DiskLimitPolicy.loop.rawValue,
            Key.detectionMask: "",
        ])

        cameraID = defaults.string(forKey: Key.cameraID)
        targetFPS = defaults.integer(forKey: Key.targetFPS)
        sensitivity = defaults.integer(forKey: Key.sensitivity)
        pixelDelta = defaults.integer(forKey: Key.pixelDelta)
        postMotionCooldown = defaults.double(forKey: Key.cooldown)
        minClipLength = defaults.double(forKey: Key.minClip)
        maxClipLength = defaults.double(forKey: Key.maxClip)
        preRollEnabled = defaults.bool(forKey: Key.preRollEnabled)
        preRoll = defaults.double(forKey: Key.preRoll)
        audioEnabled = defaults.bool(forKey: Key.audioEnabled)
        audioDeviceID = defaults.string(forKey: Key.audioDeviceID)
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: Key.triggerMode) ?? "motion") ?? .motion
        audioOnly = defaults.bool(forKey: Key.audioOnly)
        voiceSensitivity = defaults.integer(forKey: Key.voiceSensitivity)
        codec = VideoCodec(rawValue: defaults.string(forKey: Key.codec) ?? "hevc") ?? .hevc
        quality = Quality(rawValue: defaults.string(forKey: Key.quality) ?? "medium") ?? .medium
        autoCleanup = defaults.bool(forKey: Key.autoCleanup)
        cleanupDays = defaults.integer(forKey: Key.cleanupDays)
        guardMode = defaults.bool(forKey: Key.guardMode)
        monitoringSchedule = Self.decodeSchedule(defaults.string(forKey: Key.monitoringSchedule))
        recordingSchedule = Self.decodeSchedule(defaults.string(forKey: Key.recordingSchedule))
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "normal") ?? .normal
        discreetIcon = DiscreetIcon(rawValue: defaults.string(forKey: Key.discreetIcon) ?? "circle") ?? .circle
        maxStorageGB = defaults.double(forKey: Key.maxStorageGB)
        minFreeSpaceGB = defaults.double(forKey: Key.minFreeSpaceGB)
        diskLimitPolicy = DiskLimitPolicy(rawValue: defaults.string(forKey: Key.diskLimitPolicy) ?? "loop") ?? .loop
        detectionMask = defaults.string(forKey: Key.detectionMask) ?? ""
    }

    /// Whether the audio-only option currently applies: audio on AND a trigger
    /// that permits it (Continuous/Voice). Shared by the Settings views so the
    /// gate isn't re-spelled per view. `AppSettings.effectiveAudioOnly` is the
    /// capture-pipeline equivalent (it additionally requires the `audioOnly` flag).
    var audioOnlyAvailable: Bool { audioEnabled && triggerMode.allowsAudioOnly }

    func snapshot() -> AppSettings {
        AppSettings(
            cameraID: cameraID,
            targetFPS: targetFPS,
            sensitivity: sensitivity,
            pixelDelta: pixelDelta,
            postMotionCooldown: postMotionCooldown,
            minClipLength: minClipLength,
            maxClipLength: maxClipLength,
            preRollEnabled: preRollEnabled,
            preRoll: preRoll,
            audioEnabled: audioEnabled,
            audioDeviceID: audioDeviceID,
            triggerMode: triggerMode,
            voiceSensitivity: voiceSensitivity,
            audioOnly: audioOnly,
            codec: codec,
            quality: quality,
            autoCleanup: autoCleanup,
            cleanupDays: cleanupDays,
            guardMode: guardMode,
            monitoringSchedule: monitoringSchedule,
            recordingSchedule: recordingSchedule,
            maxStorageGB: maxStorageGB,
            minFreeSpaceGB: minFreeSpaceGB,
            diskLimitPolicy: diskLimitPolicy,
            detectionMask: detectionMask)
    }
}
