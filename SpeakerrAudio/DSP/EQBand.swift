import Foundation

public enum EQFilterType: String, CaseIterable, Codable, Identifiable, Sendable {
    case peak
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch
    case bandPass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .peak:
            return "Peak"
        case .lowShelf:
            return "Low Shelf"
        case .highShelf:
            return "High Shelf"
        case .lowPass:
            return "Low Pass"
        case .highPass:
            return "High Pass"
        case .notch:
            return "Notch"
        case .bandPass:
            return "Band Pass"
        }
    }

    public var supportsGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass, .notch, .bandPass:
            return false
        }
    }
}

public struct EQBand: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var type: EQFilterType
    public var frequency: Float
    public var gain: Float
    public var q: Float

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        type: EQFilterType = .peak,
        frequency: Float,
        gain: Float = 0,
        q: Float = 1.4
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    public static let defaultFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public static var defaultTenBand: [EQBand] {
        defaultFrequencies.map { frequency in
            EQBand(type: .peak, frequency: frequency, gain: 0, q: 1.4)
        }
    }

    public static func tenBand(withGains gains: [Float]) -> [EQBand] {
        let fallback = defaultTenBand
        return fallback.enumerated().map { index, band in
            var updated = band
            if index < gains.count {
                updated.gain = gains[index]
            }
            return updated
        }
    }
}
