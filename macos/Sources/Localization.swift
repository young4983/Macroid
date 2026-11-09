import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }

    func identifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .system: return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .simplifiedChinese, .english: return rawValue
        }
    }

    static let preferenceKey = "appLanguage"
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

enum L10n {
    #if SWIFT_PACKAGE
    static let resources = Bundle.module
    #else
    static let resources = Bundle.main
    #endif

    static var identifier: String { AppLanguage.saved().identifier() }
    static var locale: Locale { Locale(identifier: identifier) }

    static func bundle(for identifier: String) -> Bundle {
        guard let path = resources.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }

    static func text(_ key: String, language: String = identifier) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    // Status and diagnostics stay in their original form in the model so switching
    // language also updates existing messages, without restarting an active stream.
    // Older Android helpers send Chinese diagnostics; newer/system errors may be English.
    private static let messages: [(key: String, english: String)] = {
        guard let url = bundle(for: "en").url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [] }
        return values.map { (key: $0.key, english: $0.value) }
            .sorted { max($0.key.count, $0.english.count) > max($1.key.count, $1.english.count) }
    }()

    static func message(_ message: String, language: String = identifier) -> String {
        for entry in messages {
            for source in [entry.key, entry.english] {
                if message == source { return text(entry.key, language: language) }
                // Only translate known message prefixes. File names, paths, package
                // names and other technical details are kept verbatim.
                if message.hasPrefix(source) {
                    let tail = String(message.dropFirst(source.count))
                    if source.last?.isWhitespace == true || source.hasSuffix(":") || source.hasSuffix("：") || tail.hasPrefix("\n") {
                        return text(entry.key, language: language) + tail
                    }
                }
            }
        }
        // Java exceptions in stream.error include the exception class before the message.
        if let separator = message.range(of: ": "), message[..<separator.lowerBound].hasPrefix("java.") {
            return String(message[..<separator.upperBound]) + self.message(String(message[separator.upperBound...]), language: language)
        }
        return message
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.text(key)
    return arguments.isEmpty ? format : String(format: format, locale: L10n.locale, arguments: arguments)
}
