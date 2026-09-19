import Foundation

enum ShiftHubLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        let language = locale.identifier.hasPrefix("en") ? "en" : "ja"
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }

        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, locale: Locale, arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), arguments: arguments)
    }

    static func isEnglish(_ locale: Locale) -> Bool {
        locale.identifier.hasPrefix("en")
    }

    static func yearText(_ year: Int, locale: Locale) -> String {
        String(year)
    }

    static func monthText(_ month: Int, locale: Locale) -> String {
        String(format: "%02d", month)
    }

    static func localizedErrorDescription(_ error: Error, locale: Locale) -> String {
        let description = error.localizedDescription
        let exactKeys = [
            "カレンダーへのアクセスが許可されていません。",
            "登録先カレンダーが見つかりません。",
            "カレンダーから無効な応答が返されました。",
            "イベントの日付を作成できませんでした。",
            "Googleログイン画面を開けませんでした。",
            "Googleログインがキャンセルされました。",
            "Google認証の確認に失敗しました。もう一度ログインしてください。",
            "Googleから無効な応答が返されました。",
            "先にGoogleへログインしてください。",
            "勤務表の年月を取得できませんでした。",
            "Notionの設定を確認してください。",
            "Notionから無効な応答が返されました。",
            "Googleの認証設定を確認してください。",
            "NotionのアクセストークンとデータベースIDを設定してください。",
            "Notionのアクセストークンを設定してください。",
            "不明なエラー"
        ]
        if exactKeys.contains(description) {
            return string(description, locale: locale)
        }

        let prefixes = [
            "Google Calendar APIエラー: ": "Google Calendar APIエラー: %@",
            "Notion APIエラー（": "Notion APIエラー（%@）: %@",
            "日付を作成できませんでした: ": "日付を作成できませんでした: %@",
            "認証トークンを更新できませんでした (HTTP ": "認証トークンを更新できませんでした (HTTP %@): %@"
        ]
        for (prefix, key) in prefixes where description.hasPrefix(prefix) {
            if prefix == "Google Calendar APIエラー: " {
                return format(key, locale: locale, arguments: String(description.dropFirst(prefix.count)))
            }

            if prefix == "日付を作成できませんでした: " {
                return format(key, locale: locale, arguments: String(description.dropFirst(prefix.count)))
            }

            if prefix == "認証トークンを更新できませんでした (HTTP " {
                let remainder = String(description.dropFirst(prefix.count))
                guard let separator = remainder.range(of: "):")?.lowerBound else { break }
                let status = String(remainder[..<separator])
                let message = String(remainder[remainder.index(separator, offsetBy: 2)...])
                return format(key, locale: locale, arguments: status, message)
            }

            let remainder = String(description.dropFirst(prefix.count))
            guard let separator = remainder.firstIndex(of: "）") else { break }
            let status = String(remainder[..<separator])
            let messageStart = remainder.index(after: separator)
            let message = String(remainder[messageStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return format(key, locale: locale, arguments: status, message)
        }

        return description
    }
}
