import Foundation

// MARK: - App Settings

struct AppSettings: Codable {
    var parametricBands: [EQBand] = EQBand.defaultTenBand
    var isEnabled: Bool = true
    var isEQFiltersEnabled: Bool = true
    var preGain: Float = 0.0
    var outputGain: Float = 0.0
    var limiterEnabled: Bool = false
    var limiterCeilingDB: Float = -1.0
    var autoStopClippingEnabled: Bool = false
    var volume: Float = 1.0
    var usePerDeviceVolume: Bool = true
    var autoSaveEnabled: Bool = true
    var selectedBuiltInPresetName: String? = nil
    var selectedCustomPresetID: String? = nil
    var selectedInputDeviceID: Int32? = nil
    var selectedOutputDeviceID: Int32? = nil
    var selectedOutputDeviceUIDs: [String]? = nil
    var shortcutOutputDeviceUIDs: [String]? = nil
    var normalizeSpectrumAnalyzer: Bool = false
    var preferredIOBufferFrames: Int32 = Int32(AudioEngine.defaultIOBufferFrames)
    var ringBufferCapacityMultiplier: Int32 = Int32(AudioEngine.defaultRingBufferCapacityMultiplier)
    var latencyTargetMultiplier: Int32 = Int32(AudioEngine.defaultLatencyTargetMultiplier)

    enum CodingKeys: String, CodingKey {
        case parametricBands
        case isEnabled
        case isEQFiltersEnabled
        case preGain
        case outputGain
        case limiterEnabled
        case limiterCeilingDB
        case autoStopClippingEnabled
        case volume
        case usePerDeviceVolume
        case autoSaveEnabled
        case selectedBuiltInPresetName
        case selectedCustomPresetID
        case selectedInputDeviceID
        case selectedOutputDeviceID
        case selectedOutputDeviceUIDs
        case shortcutOutputDeviceUIDs
        case normalizeSpectrumAnalyzer
        case preferredIOBufferFrames
        case ringBufferCapacityMultiplier
        case latencyTargetMultiplier
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        parametricBands = try container.decodeIfPresent([EQBand].self, forKey: .parametricBands) ?? EQBand.defaultTenBand
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isEQFiltersEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEQFiltersEnabled) ?? true
        preGain = try container.decodeIfPresent(Float.self, forKey: .preGain) ?? 0.0
        outputGain = try container.decodeIfPresent(Float.self, forKey: .outputGain) ?? 0.0
        limiterEnabled = try container.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? false
        limiterCeilingDB = try container.decodeIfPresent(Float.self, forKey: .limiterCeilingDB) ?? -1.0
        autoStopClippingEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopClippingEnabled) ?? false
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        usePerDeviceVolume = try container.decodeIfPresent(Bool.self, forKey: .usePerDeviceVolume) ?? true
        autoSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSaveEnabled) ?? true
        selectedBuiltInPresetName = try container.decodeIfPresent(String.self, forKey: .selectedBuiltInPresetName)
        selectedCustomPresetID = try container.decodeIfPresent(String.self, forKey: .selectedCustomPresetID)
        selectedInputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedInputDeviceID)
        selectedOutputDeviceID = try container.decodeIfPresent(Int32.self, forKey: .selectedOutputDeviceID)
        selectedOutputDeviceUIDs = try container.decodeIfPresent([String].self, forKey: .selectedOutputDeviceUIDs)
        shortcutOutputDeviceUIDs = try container.decodeIfPresent([String].self, forKey: .shortcutOutputDeviceUIDs)
        normalizeSpectrumAnalyzer = try container.decodeIfPresent(Bool.self, forKey: .normalizeSpectrumAnalyzer) ?? false
        preferredIOBufferFrames = try container.decodeIfPresent(Int32.self, forKey: .preferredIOBufferFrames) ?? Int32(AudioEngine.defaultIOBufferFrames)
        ringBufferCapacityMultiplier = try container.decodeIfPresent(Int32.self, forKey: .ringBufferCapacityMultiplier) ?? Int32(AudioEngine.defaultRingBufferCapacityMultiplier)
        latencyTargetMultiplier = try container.decodeIfPresent(Int32.self, forKey: .latencyTargetMultiplier) ?? Int32(AudioEngine.defaultLatencyTargetMultiplier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(parametricBands, forKey: .parametricBands)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isEQFiltersEnabled, forKey: .isEQFiltersEnabled)
        try container.encode(preGain, forKey: .preGain)
        try container.encode(outputGain, forKey: .outputGain)
        try container.encode(limiterEnabled, forKey: .limiterEnabled)
        try container.encode(limiterCeilingDB, forKey: .limiterCeilingDB)
        try container.encode(autoStopClippingEnabled, forKey: .autoStopClippingEnabled)
        try container.encode(volume, forKey: .volume)
        try container.encode(usePerDeviceVolume, forKey: .usePerDeviceVolume)
        try container.encode(autoSaveEnabled, forKey: .autoSaveEnabled)
        try container.encode(selectedBuiltInPresetName, forKey: .selectedBuiltInPresetName)
        try container.encode(selectedCustomPresetID, forKey: .selectedCustomPresetID)
        try container.encode(selectedInputDeviceID, forKey: .selectedInputDeviceID)
        try container.encode(selectedOutputDeviceID, forKey: .selectedOutputDeviceID)
        try container.encode(selectedOutputDeviceUIDs, forKey: .selectedOutputDeviceUIDs)
        try container.encode(shortcutOutputDeviceUIDs, forKey: .shortcutOutputDeviceUIDs)
        try container.encode(normalizeSpectrumAnalyzer, forKey: .normalizeSpectrumAnalyzer)
        try container.encode(preferredIOBufferFrames, forKey: .preferredIOBufferFrames)
        try container.encode(ringBufferCapacityMultiplier, forKey: .ringBufferCapacityMultiplier)
        try container.encode(latencyTargetMultiplier, forKey: .latencyTargetMultiplier)
    }
}

// MARK: - App Settings Store

class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let settingsKey = "speakerr.AppSettings"
    private var cachedSettings: AppSettings?
    private var cachedEncodedSettings: Data?

    init() {
        _ = loadFromDefaults()
    }

    /// Loads the current settings from persistent storage
    func load() -> AppSettings? {
        if let cached = cachedSettings {
            return cached
        }
        return loadFromDefaults()
    }

    /// Returns current settings or defaults if none are stored yet.
    func current() -> AppSettings {
        return load() ?? AppSettings()
    }

    /// Updates the settings using a mutation closure and persists the result
    func update(_ mutate: (inout AppSettings) -> Void) {
        var settings = current()
        mutate(&settings)
        save(settings)
    }

    /// Replaces the current settings with a new instance
    func replace(with settings: AppSettings) {
        save(settings)
    }

    /// Resets all settings to their defaults
    func reset() {
        let defaults = AppSettings()
        save(defaults)
    }

    // MARK: - Private Methods

    private func loadFromDefaults() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let settings = try decoder.decode(AppSettings.self, from: data)
            cachedSettings = settings
            cachedEncodedSettings = data
            return settings
        } catch {
            print("AppSettingsStore: Failed to decode settings: \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ settings: AppSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)

            if let cachedData = cachedEncodedSettings, cachedData == data {
                return
            }

            UserDefaults.standard.set(data, forKey: settingsKey)
            cachedSettings = settings
            cachedEncodedSettings = data
        } catch {
            print("AppSettingsStore: Failed to encode settings: \(error.localizedDescription)")
        }
    }
}
