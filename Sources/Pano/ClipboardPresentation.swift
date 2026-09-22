import AppKit
import SwiftUI

enum ClipKind: String, CaseIterable, Identifiable {
    case text, link, code, color, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Metin"
        case .link: return "Bağlantı"
        case .code: return "Kod"
        case .color: return "Renk"
        case .image: return "Resim"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "paintpalette"
        case .image: return "photo"
        }
    }
    var tint: Color {
        switch self {
        case .text: return Color(hex: 0xA8A8B3)
        case .link: return Color(hex: 0x5E9EFF)
        case .code: return Color(hex: 0xBF7AF0)
        case .color: return Color(hex: 0xF0A05E)
        case .image: return Color(hex: 0x5ED4A0)
        }
    }
}

extension ClipboardEntry {
    var clipKind: ClipKind {
        if imageFilename != nil { return .image }
        if colorValue != nil { return .color }
        if linkURL != nil { return .link }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["import ", "func ", "function ", "const ", "let ", "var ", "class ",
                        "struct ", "def ", "SELECT ", "#!/", "<!DOCTYPE", "<html", "@main"]
        if prefixes.contains(where: { value.hasPrefix($0) })
            || ((value.hasPrefix("{") && value.hasSuffix("}"))
                || (value.hasPrefix("[") && value.hasSuffix("]"))) {
            return .code
        }
        return .text
    }

    var linkURL: URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }), let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var colorValue: UInt32? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        let digits = String(value.dropFirst())
        guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
        return UInt32(expanded, radix: 16)
    }

    var cardTitle: String {
        if let label, !label.isEmpty { return label }
        if imageFilename != nil { return "Resim" }
        if let host = linkURL?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return String(text.split(whereSeparator: { $0.isNewline }).first?.prefix(90) ?? "")
    }

    var relativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(copiedAt)))
        if seconds < 60 { return "Az önce" }
        if seconds < 3_600 { return "\(seconds / 60) dk önce" }
        if seconds < 86_400 { return "\(seconds / 3_600) sa önce" }
        if seconds < 604_800 { return "\(seconds / 86_400) gün önce" }
        return copiedAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "tr_TR")))
    }
}

@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
