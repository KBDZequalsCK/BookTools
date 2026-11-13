import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh"
    case english = "en"

    /// 语言名称始终用该语言自己的写法，便于在任何界面语言下都能找到母语。
    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

enum AppLocalization {
    static let defaultsKey = "appLanguage"

    private(set) static var language: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.chinese.rawValue
        return AppLanguage(rawValue: raw) ?? .chinese
    }()

    static var isEnglish: Bool { language == .english }

    static func setLanguage(_ language: AppLanguage) {
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
    }
}

/// 界面文案统一走这里：中文在前、英文在后；默认中文。
func L(_ chinese: String, _ english: String) -> String {
    AppLocalization.isEnglish ? english : chinese
}
