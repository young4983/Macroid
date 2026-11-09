import Combine
import SwiftUI

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: AppLanguage.preferenceKey)
            revision &+= 1
        }
    }
    @Published private(set) var revision = 0
    private var localeObserver: AnyCancellable?

    private init() {
        selection = AppLanguage.saved()
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }
}

struct LanguagePicker: View {
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("应用语言"), selection: $language.selection) {
                Text(L("跟随系统")).tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
                Text("English").tag(AppLanguage.english)
            }
            Text(L("语言更改立即生效，并在下次启动时保留。跟随系统时，中文设备显示简体中文，其他语言显示英文。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
