import Foundation

public enum InteractiveDelayCommand: Equatable, Sendable {
    case adjust(device: Character, milliseconds: Double)
    case set(device: Character, milliseconds: Double)
    case status
    case help
    case quit

    public static func parse(_ input: String) -> InteractiveDelayCommand? {
        let parts = input.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            switch parts[0] {
            case "status": return .status
            case "help": return .help
            case "quit", "q", "exit": return .quit
            default: return nil
            }
        }
        guard parts.count == 2, let device = parts[0].first, device == "a" || device == "b", let value = Double(parts[1]) else { return nil }
        if parts[1].hasPrefix("+") || parts[1].hasPrefix("-") {
            return .adjust(device: device, milliseconds: value)
        }
        return .set(device: device, milliseconds: value)
    }
}
