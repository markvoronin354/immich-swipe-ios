import Foundation
import SwiftUI

/// How an account's avatar looks when it has no picture: Immich's colour names (as the Android app
/// maps them) and the first letter of the name.
nonisolated enum AvatarStyle {
    /// Immich's avatar colour name as 0xRRGGBB. Unknown or missing names are purple, as on Android.
    static func rgb(forColorName name: String?) -> UInt32 {
        switch name?.lowercased() {
        case "primary": 0xADCBFA
        case "pink": 0xE91E63
        case "red": 0xF44336
        case "yellow": 0xFFEB3B
        case "blue": 0x2196F3
        case "green": 0x4CAF50
        case "purple": 0x9C27B0
        case "orange": 0xFF9800
        case "gray", "grey": 0x9E9E9E
        case "amber": 0xFFC107
        case "cyan": 0x00BCD4
        case "indigo": 0x3F51B5
        case "lime": 0xCDDC39
        case "teal": 0x009688
        default: 0x9C27B0
        }
    }

    /// The first letter or digit of the name, uppercased. Nil when there is none, so a person icon shows.
    static func initial(of name: String?) -> Character? {
        name?.first { $0.isLetter || $0.isNumber }.map { Character($0.uppercased()) }
    }

    /// Light colours get dark text and dark colours get white text (relative luminance above 0.6).
    static func prefersDarkText(onRGB rgb: UInt32) -> Bool {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((rgb >> 16) & 0xFF) + 0.7152 * linear((rgb >> 8) & 0xFF) + 0.0722 * linear(rgb & 0xFF)
        return luminance > 0.6
    }

    static func color(forColorName name: String?) -> Color {
        let rgb = rgb(forColorName: name)
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// The three states the connection indicator shows, as on Android.
nonisolated enum ConnectionLevel: Equatable, Sendable {
    case online, issues, offline, unknown

    init(_ event: ConnectionEvent?) {
        switch event {
        case .online: self = .online
        // The server answered, or started to, but something is wrong.
        case .authenticationFailed, .serverUnavailable, .serverError, .timedOut: self = .issues
        // The server couldn't be reached at all.
        case .dnsFailure, .noInternet: self = .offline
        case nil: self = .unknown
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .online: "Server online"
        case .issues: "Issues detected"
        case .offline: "Server unreachable"
        case .unknown: "Unknown status"
        }
    }

    var color: Color {
        switch self {
        case .online: Color(red: 0.30, green: 0.69, blue: 0.31)
        case .issues: Color(red: 1.0, green: 0.60, blue: 0.0)
        case .offline: Color(red: 0.96, green: 0.26, blue: 0.21)
        case .unknown: .gray
        }
    }
}
