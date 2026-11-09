import Foundation
import XCTest
@testable import MacroidWire

final class LocalizationTests: XCTestCase {
    func testSystemLanguageAndExplicitOverrides() {
        XCTAssertEqual(AppLanguage.system.identifier(preferredLanguages: ["zh-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.identifier(preferredLanguages: ["zh-Hant-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.identifier(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.identifier(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.system.identifier(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.english.identifier(preferredLanguages: ["zh-CN"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.identifier(preferredLanguages: ["en-US"]), "zh-Hans")
    }

    func testSavedPreferenceSurvivesReloadAndInvalidValuesFollowSystem() throws {
        let suite = "MacroidLocalizationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .english)
        defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
        defaults.set(AppLanguage.system.rawValue, forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
    }

    func testBothShippedCatalogsAreCompleteAndFormatArgumentsAgree() throws {
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertGreaterThan(english.count, 200)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: #"%\d+\$[@dfl]+"#)
        for key in english.keys {
            let en = try XCTUnwrap(english[key]), zh = try XCTUnwrap(chinese[key])
            XCTAssertFalse(en.isEmpty, key)
            XCTAssertFalse(zh.isEmpty, key)
            let arguments: (String) -> [String] = { value in
                placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                    .map { (value as NSString).substring(with: $0.range) }.sorted()
            }
            XCTAssertEqual(arguments(en), arguments(zh), key)
        }
        XCTAssertEqual(L10n.text("连接设备", language: "en"), "Connect device")
        XCTAssertEqual(L10n.text("连接设备", language: "zh-Hans"), "连接设备")
        XCTAssertEqual(String(format: L10n.text("已连接 · %1$@ · Android %2$@", language: "en"), "USB", "14"), "Connected · USB · Android 14")
    }

    func testExistingMessagesCanSwitchLanguagesWithoutChangingDiagnosticDetails() {
        let original = "无法使用请求尺寸，已恢复上一尺寸：codec.error 0x80001001"
        let english = L10n.message(original, language: "en")
        XCTAssertEqual(english, "Could not use the requested size. Restored the previous size: codec.error 0x80001001")
        XCTAssertEqual(L10n.message(english, language: "zh-Hans"), original)
        XCTAssertEqual(L10n.message("正在上传 报告.txt", language: "en"), "Uploading 报告.txt")
        XCTAssertEqual(L10n.message("java.io.IOException: 请先在手机上解锁，再开启关屏使用", language: "en"), "java.io.IOException: Unlock your phone before turning its screen off")
        XCTAssertEqual(L10n.message("/sdcard/连接设备.txt", language: "en"), "/sdcard/连接设备.txt")
        XCTAssertEqual(L10n.message("Unknown OEM error: 123", language: "zh-Hans"), "Unknown OEM error: 123")
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
}
