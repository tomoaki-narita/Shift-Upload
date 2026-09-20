import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

// Settings, About, missing-title selection, and shift-definition screens.
enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }
}

#if os(macOS)
private enum ShiftHubMacSettingsPane: String, CaseIterable, Identifiable {
    case general
    case shifts
    case calendars
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "一般"
        case .shifts:
            return "イベント管理"
        case .calendars:
            return "カレンダー設定"
        case .about:
            return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "言語とiCloud同期を設定"
        case .shifts:
            return "イベントタイトルと開始・終了時刻を管理"
        case .calendars:
            return "カレンダー接続と登録先を設定"
        case .about:
            return "アプリ情報・プライバシー・著作権"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .shifts:
            return "clock.badge.checkmark"
        case .calendars:
            return "calendar.badge.clock"
        case .about:
            return "info.circle"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["General", "Language", "言語", "iCloud", "同期"]
        case .shifts:
            return ["Shifts", "Shift", "勤務", "タイトル", "時間"]
        case .calendars:
            return ["Calendar", "Apple", "Google", "Notion", "カレンダー"]
        case .about:
            return ["About", "Privacy", "Copyright", "情報", "プライバシー", "著作権"]
        }
    }
}

private struct ShiftHubMacSettingsView: View {
    @Binding var definitions: [ShiftDefinition]
    @Binding var appLanguage: String
    @Binding var isCloudSyncEnabled: Bool

    @State private var selectedPane: ShiftHubMacSettingsPane = .general
    @State private var sidebarSearchText = ""
    @State private var isShiftSettingsPresented = false
    @State private var isCalendarSettingsPresented = false

    private var locale: Locale {
        Locale(identifier: appLanguage)
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var filteredPanes: [ShiftHubMacSettingsPane] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ShiftHubMacSettingsPane.allCases
        }

        return ShiftHubMacSettingsPane.allCases.filter { pane in
            pane.title.localizedCaseInsensitiveContains(query)
                || pane.subtitle.localizedCaseInsensitiveContains(query)
                || pane.searchKeywords.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 220)

            Divider()

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShiftSettingsPresented) {
            ShiftDefinitionSettingsView(definitions: $definitions)
                .environment(\.locale, Locale(identifier: appLanguage))
        }
        .sheet(isPresented: $isCalendarSettingsPresented) {
            CalendarSettingsView()
                .environment(\.locale, Locale(identifier: appLanguage))
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("検索", text: $sidebarSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 18)

            VStack(spacing: 2) {
                ForEach(filteredPanes) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        ShiftHubMacSettingsSidebarRow(
                            title: localized(pane.title),
                            systemImage: pane.systemImage,
                            isSelected: selectedPane == pane
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHero(for: selectedPane)
                settingsContent(for: selectedPane)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func settingsHero(for pane: ShiftHubMacSettingsPane) -> some View {
        VStack(spacing: 8) {
            ShiftHubMacSettingsHeroIcon(systemImage: pane.systemImage)

            Text(localized(pane.title))
                .font(.title2.weight(.semibold))

            Text(localized(pane.subtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(ShiftHubMacSettingsCardBackground())
    }

    @ViewBuilder
    private func settingsContent(for pane: ShiftHubMacSettingsPane) -> some View {
        switch pane {
        case .general:
            generalSettings
        case .shifts:
            detailActionCard(
                title: localized("イベント管理"),
                subtitle: localized("イベントタイトルと開始・終了時刻を管理"),
                systemImage: "clock.badge.checkmark"
            ) {
                isShiftSettingsPresented = true
            }
        case .calendars:
            detailActionCard(
                title: localized("カレンダー設定"),
                subtitle: localized("Apple・Google・Notionの接続先を管理"),
                systemImage: "calendar.badge.clock"
            ) {
                isCalendarSettingsPresented = true
            }
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        ShiftHubMacSettingsSectionCard {
            ShiftHubMacSettingsRow(

                title: localized("言語"),
                subtitle: localized("アプリの表示言語"),
                systemImage: "globe"
            ) {
                Picker("言語", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Divider()

            ShiftHubMacSettingsRow(
                title: localized("iCloud同期"),
                subtitle: localized("設定とPDFをiCloudで同期します。"),
                systemImage: "icloud"
            ) {
                Toggle("", isOn: $isCloudSyncEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private func detailActionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        ShiftHubMacSettingsSectionCard {
            Button(action: action) {
                HStack(spacing: 12) {
                    ShiftHubMacSettingsRowIcon(systemImage: systemImage)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.medium))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            ShiftHubMacSettingsSectionCard {
                HStack(spacing: 14) {
                    Image("CalHubIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cal Hub")
                            .font(.title3.weight(.semibold))
                        Text(shiftHubAppVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shiftHubCopyrightText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("このアプリについて"))
                    .font(.headline)
                Text(localized("イベント設定に保存したイベントを、Appleカレンダー、Googleカレンダー、Notionデータベースへ登録・変更・削除できるアプリです。勤務表のPDFを読み込み、日付ごとのイベントを抽出して登録できます。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("主な機能"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("PDFスキャン"),
                    detail: localized("文字データを持つ横向きPDFから、保存した名前に一致する行を抽出します。抽出結果はカレンダー表示、横並び表示、リスト表示を切り替えられ、日付ごとのイベント名を編集・削除できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("保存済みPDF"),
                    detail: localized("読み込んだPDFをアプリ内に保存し、一覧から再解析・削除できます。同じ内容のPDFは重複保存しません。保存したPDFのプレビュー、ページ移動、拡大縮小にも対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("カレンダー登録"),
                    detail: localized("Appleカレンダー、Googleカレンダー、Notionデータベースを登録先として選択できます。保存済みイベントの一覧から登録できるほか、トップ画面ではタイトルと開始・終了日時を指定したイベントを登録できます。PDFスキャンと複数選択は同日登録に対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント管理"),
                    detail: localized("月を移動し、日付ごとの通常イベントを確認、変更、削除できます。空の日付への新規登録、既存イベントの置き換えにも対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("複数選択"),
                    detail: localized("複数の日付を選択し、保存済みのイベントをまとめて登録できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("祝日表示"),
                    detail: localized("Googleカレンダーの「日本の祝日」を登録先と一緒に表示できます。祝日は表示専用で、イベント件数には含まれません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント設定"),
                    detail: localized("イベントタイトルと開始・終了時刻を保存、編集、並べ替え、削除できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("iCloud同期"),
                    detail: localized("設定と保存済みPDFをiCloudで同期できます。カレンダー上のイベントと認証情報は同期しません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("カレンダーキャッシュ"),
                    detail: localized("表示中の月を中心に前後12か月をキャッシュし、月移動時はキャッシュを先に表示します。表示範囲外の月は破棄し、手動更新、iCloud同期完了、接続先設定の変更後に再取得します。Mac版ではアプリの再アクティブ化だけでは再取得しません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("言語切替"),
                    detail: localized("設定から日本語と英語を切り替えられます。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("対応形式と注意点"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("勤務表入力条件"),
                    detail: localized("文字を選択・コピーできる文字情報を持つPDFのみ対応しています。PDFを開いたときに文字を選択できないスキャン画像だけのPDFは対象外です。職員名と1日から月末までの日付が表形式で配置され、日付が連続して並ぶ勤務表を使用してください。日付が横方向に並ぶ形式と、日付が縦方向に並び職員名が上部に並ぶ形式に対応しています。PDFページの縦横比ではなく、文字の配置から横型・縦型を自動判定します。表の構造や日付の並びを判別できないPDFには対応していません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("年月の判定"),
                    detail: localized("PDFから年月を取得できない場合は、ファイル名を「2026-01.pdf」のようなYYYY-MM形式にしてください。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント名の照合"),
                    detail: localized("PDFから抽出した勤務名がイベント設定にない場合は、登録前に保存するか、登録時にスキップされます。新しく保存したイベントの初期時間は8:30-17:30です。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("休の登録"),
                    detail: localized("「休」は登録時に含めるか選択できます。AppleカレンダーとGoogleカレンダーでは終日、Notionでは00:00-23:59の時間付きデータとして登録します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("日付カードの表示"),
                    detail: localized("日付カードには時間順に最大3件を表示します。3件以上の場合、カード内の時間は省略され、日付メニューで全件を確認できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("日をまたぐイベント"),
                    detail: localized("トップ画面から開始日時と終了日時を指定して登録できます。日付をまたぐイベントは開始日から終了日まで帯で表示し、週や月の境界では帯を分割します。日付メニューでは開始日・終了日を含む範囲を表示します。PDFスキャンと複数選択からは登録できません。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("接続の準備"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("Appleカレンダー"),
                    detail: localized("用意するもの: Apple IDでiCloudにサインインし、カレンダーを有効にした端末。クライアントIDやトークンは不要です。\n設定方法: 端末のカレンダーへのアクセスを許可し、カレンダー設定で「カレンダー一覧を取得」から登録先カレンダーを選択します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("Googleカレンダー"),
                    detail: localized("用意するもの: Googleアカウント。\n設定方法: Googleログインを選択し、カレンダーへのアクセスを許可して登録先を選択してください。OAuthクライアントの設定はアプリ側で管理します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("Notion DB"),
                    detail: localized("用意するもの: Notionの内部インテグレーション、アクセストークン、対象データベースのID。データベースにはタイトル型・日付型・複数選択型のプロパティが必要です。\n設定方法: NotionのMy integrationsで内部インテグレーションを作成してトークンを取得し、対象データベースの接続にそのインテグレーションを追加します。データベースURLからIDを確認して入力し、列を取得後にタイトル列・日付列・タグ列・タグ値を選択してください。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("プライバシーポリシー"))
                    .font(.headline)
                Text(localized("このアプリは、ユーザーが選択したPDFと、カレンダー登録に必要な設定を使用します。"))
                Text(localized("Appleカレンダーを使用する場合、カレンダーへのアクセスはイベントの読み取りと登録のためにのみ使用します。"))
                Text(localized("GoogleカレンダーとNotionを使用する場合、入力された認証情報は登録先との通信に使用されます。"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var shiftHubAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "Unknown"
        }
    }

    private var shiftHubCopyrightText: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Tomoaki Narita. All rights reserved."
    }
}

private struct ShiftHubMacSettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ShiftHubMacSettingsRowIcon(systemImage: systemImage, isSelected: isSelected)

            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        }
    }
}

private struct ShiftHubMacSettingsHeroIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 34, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 58, height: 58)
    }
}

private struct ShiftHubMacSettingsCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }
}

private struct ShiftHubMacSettingsSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShiftHubMacSettingsCardBackground())
    }
}

private struct ShiftHubMacSettingsRow<Control: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            ShiftHubMacSettingsRowIcon(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            control
        }
        .frame(minHeight: 44)
        .padding(.vertical, 3)
    }
}

private struct ShiftHubMacSettingsRowIcon: View {
    let systemImage: String
    var isSelected = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 22, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
            }
    }
}

private struct ShiftHubMacAboutFeatureRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}
#endif

struct AppSettingsView: View {
    @Binding var definitions: [ShiftDefinition]

    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
    @AppStorage("iCloudSyncEnabled") private var isCloudSyncEnabled = true

    var body: some View {
#if os(macOS)
        ShiftHubMacSettingsView(
            definitions: $definitions,
            appLanguage: $appLanguage,
            isCloudSyncEnabled: $isCloudSyncEnabled
        )
        .environment(\.locale, Locale(identifier: appLanguage))
        .navigationTitle("設定")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(
            minWidth: 720,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: .infinity,
            alignment: .topLeading
        )
#else
        Form {
            Section("一般") {
                Picker("言語", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }

                Toggle(isOn: $isCloudSyncEnabled) {
                    Label("iCloud同期", systemImage: "icloud")
                }

                Text("設定とPDFをiCloudで同期します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("イベント") {
                NavigationLink {
                    ShiftDefinitionSettingsView(definitions: $definitions)
                } label: {
                    Label("イベント管理", systemImage: "clock.badge.checkmark")
                }
                    Text("イベントタイトルと開始・終了時刻を管理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("カレンダー") {
                NavigationLink {
                    CalendarSettingsView()
                } label: {
                    Label("カレンダー設定", systemImage: "calendar.badge.clock")
                }
                Text("Apple・Google・Notionの接続先を管理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                NavigationLink {
                    ShiftHubAboutView()
                } label: {
                            Label("Cal Hubについて", systemImage: "info.circle")
                }
            }
        }
        .environment(\.locale, Locale(identifier: appLanguage))
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

}

private struct ShiftHubAboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "Unknown"
        }
    }

    private var copyrightText: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Tomoaki Narita. All rights reserved."
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("CalHubIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cal Hub")
                            .font(.title3.weight(.semibold))
                        Text(appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(copyrightText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("このアプリについて") {
                Text("イベント設定に保存したイベントを、Appleカレンダー、Googleカレンダー、Notionデータベースへ登録・変更・削除できるアプリです。勤務表のPDFを読み込み、日付ごとのイベントを抽出して登録できます。")
            }

            Section("主な機能") {
                ShiftHubAboutRow(
                    title: "PDFスキャン",
                    detail: "文字データを持つ横向きPDFから、保存した名前に一致する行を抽出します。抽出結果はカレンダー表示、横並び表示、リスト表示を切り替えられ、日付ごとのイベント名を編集・削除できます。"
                )
                ShiftHubAboutRow(
                    title: "保存済みPDF",
                    detail: "読み込んだPDFをアプリ内に保存し、一覧から再解析・削除できます。同じ内容のPDFは重複保存しません。保存したPDFのプレビュー、ページ移動、拡大縮小にも対応します。"
                )
                ShiftHubAboutRow(
                    title: "カレンダー登録",
                    detail: "Appleカレンダー、Googleカレンダー、Notionデータベースを登録先として選択できます。保存済みイベントの一覧から登録できるほか、トップ画面ではタイトルと開始・終了日時を指定したイベントを登録できます。PDFスキャンと複数選択は同日登録に対応します。"
                )
                ShiftHubAboutRow(
                    title: "イベント管理",
                    detail: "月を移動し、日付ごとの通常イベントを確認、変更、削除できます。空の日付への新規登録、既存イベントの置き換えにも対応します。"
                )
                ShiftHubAboutRow(
                    title: "複数選択",
                    detail: "複数の日付を選択し、保存済みのイベントをまとめて登録できます。"
                )
                ShiftHubAboutRow(
                    title: "祝日表示",
                    detail: "Googleカレンダーの「日本の祝日」を登録先と一緒に表示できます。祝日は表示専用で、イベント件数には含まれません。"
                )
                ShiftHubAboutRow(
                    title: "イベント設定",
                    detail: "イベントタイトルと開始・終了時刻を保存、編集、並べ替え、削除できます。"
                )
                ShiftHubAboutRow(
                    title: "iCloud同期",
                    detail: "設定と保存済みPDFをiCloudで同期できます。カレンダー上のイベントと認証情報は同期しません。"
                )
                ShiftHubAboutRow(
                    title: "カレンダーキャッシュ",
                    detail: "表示中の月を中心に前後12か月をキャッシュし、月移動時はキャッシュを先に表示します。表示範囲外の月は破棄し、手動更新、バックグラウンドからの復帰、iCloud同期完了、接続先設定の変更後に再取得します。"
                )
                ShiftHubAboutRow(
                    title: "言語切替",
                    detail: "設定から日本語と英語を切り替えられます。"
                )
            }

            Section("対応形式と注意点") {
                ShiftHubAboutRow(
                    title: "勤務表入力条件",
                    detail: "文字を選択・コピーできる文字情報を持つPDFのみ対応しています。PDFを開いたときに文字を選択できないスキャン画像だけのPDFは対象外です。職員名と1日から月末までの日付が表形式で配置され、日付が連続して並ぶ勤務表を使用してください。日付が横方向に並ぶ形式と、日付が縦方向に並び職員名が上部に並ぶ形式に対応しています。PDFページの縦横比ではなく、文字の配置から横型・縦型を自動判定します。表の構造や日付の並びを判別できないPDFには対応していません。"
                )
                ShiftHubAboutRow(
                    title: "年月の判定",
                    detail: "PDFから年月を取得できない場合は、ファイル名を「2026-01.pdf」のようなYYYY-MM形式にしてください。"
                )
                ShiftHubAboutRow(
                    title: "イベント名の照合",
                    detail: "PDFから抽出した勤務名がイベント設定にない場合は、登録前に保存するか、登録時にスキップされます。新しく保存したイベントの初期時間は8:30-17:30です。"
                )
                ShiftHubAboutRow(
                    title: "休の登録",
                    detail: "「休」は登録時に含めるか選択できます。AppleカレンダーとGoogleカレンダーでは終日、Notionでは00:00-23:59の時間付きデータとして登録します。"
                )
                ShiftHubAboutRow(
                    title: "日付カードの表示",
                    detail: "日付カードには時間順に最大3件を表示します。3件以上の場合、カード内の時間は省略され、日付メニューで全件を確認できます。"
                )
                ShiftHubAboutRow(
                    title: "日をまたぐイベント",
                    detail: "トップ画面から開始日時と終了日時を指定して登録できます。日付をまたぐイベントは開始日から終了日まで帯で表示し、週や月の境界では帯を分割します。日付メニューでは開始日・終了日を含む範囲を表示します。PDFスキャンと複数選択からは登録できません。"
                )
            }

            Section("接続の準備") {
                ShiftHubAboutRow(
                    title: "Appleカレンダー",
                    detail: "用意するもの: Apple IDでiCloudにサインインし、カレンダーを有効にした端末。クライアントIDやトークンは不要です。\n設定方法: 端末のカレンダーへのアクセスを許可し、カレンダー設定で「カレンダー一覧を取得」から登録先カレンダーを選択します。"
                )
                ShiftHubAboutRow(
                    title: "Googleカレンダー",
                    detail: "用意するもの: Googleアカウント。\n設定方法: Googleログインを選択し、カレンダーへのアクセスを許可して登録先を選択してください。OAuthクライアントの設定はアプリ側で管理します。"
                )
                ShiftHubAboutRow(
                    title: "Notion DB",
                    detail: "用意するもの: Notionの内部インテグレーション、アクセストークン、対象データベースのID。データベースにはタイトル型・日付型・複数選択型のプロパティが必要です。\n設定方法: NotionのMy integrationsで内部インテグレーションを作成してトークンを取得し、対象データベースの接続にそのインテグレーションを追加します。データベースURLからIDを確認して入力し、列を取得後にタイトル列・日付列・タグ列・タグ値を選択してください。"
                )
            }

            Section("プライバシーポリシー") {
                Text("勤務表、イベント設定、登録先の設定は、この端末に保存されます。iCloud同期を有効にした場合は、同期対象の設定と保存済みPDFがユーザー専用のiCloud領域に保存されます。")
                Text("Appleカレンダー、Googleカレンダー、Notionの情報は、ユーザーが接続・取得・登録を実行した場合にのみ、それぞれのサービスへ送信されます。Notionのアクセストークンなどの認証情報は端末の安全な保存領域で管理されます。")
                Text("このアプリは、ユーザーが選択した勤務表やカレンダーの内容を広告目的で利用しません。各サービスの利用やデータ保存については、それぞれのサービスのポリシーも適用されます。")
            }

            Section("著作権") {
                Text(copyrightText)
                Text("Cal Hubの名称、画面、ソフトウェアおよび関連資料の著作権は、別途記載がある場合を除き、Tomoaki Naritaに帰属します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("サポート") {
                Link(destination: URL(string: "https://github.com/tomoaki-narita/Shift-Upload")!) {
                    Label("サポート・ソースコード", systemImage: "link")
                }
            }
        }
        .navigationTitle("About")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct ShiftHubAboutRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MissingShiftTimeDraft {
    var startMinutes: Int
    var endMinutes: Int
}

struct MissingShiftSelectionView: View {
    let titles: [String]
    let onComplete: (Set<String>, [ShiftDefinition]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedTitles: Set<String>
    @State private var timeDrafts: [String: MissingShiftTimeDraft]
    @State private var validationMessage: String?

    init(
        titles: [String],
        onComplete: @escaping (Set<String>, [ShiftDefinition]) -> Void
    ) {
        self.titles = titles
        self.onComplete = onComplete
        _selectedTitles = State(initialValue: [])
        _timeDrafts = State(initialValue: titles.reduce(into: [:]) { drafts, title in
            drafts[title] = MissingShiftTimeDraft(startMinutes: 510, endMinutes: 1050)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("未登録イベント"))
                        .font(.title2.bold())

                    Text(localized("保存するイベントを選択してください。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("保存")) {
                    save()
                }
                .buttonStyle(.borderedProminent)

                Button(localized("閉じる")) {
                    onComplete([], [])
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            List(titles, id: \.self) { title in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: selectionBinding(for: title)) {
                        Text(title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
#if os(macOS)
                    .toggleStyle(.checkbox)
#endif

                    if selectedTitles.contains(title) {
                        timePickers(for: title)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            .frame(minWidth: 360, minHeight: 220)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 420, height: 420)
#endif
        .alert(
            Text(localized("保存できません")),
            isPresented: validationAlertBinding
        ) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var validationAlertBinding: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { isPresented in
                if !isPresented {
                    validationMessage = nil
                }
            }
        )
    }

    private var timePickerLocale: Locale {
        locale.identifier.hasPrefix("ja")
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_GB")
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    @ViewBuilder
    private func timePickers(for title: String) -> some View {
        HStack(spacing: 24) {
            timePickerRow(
                label: localized("開始"),
                selection: startDateBinding(for: title)
            )
            timePickerRow(
                label: localized("終了"),
                selection: endDateBinding(for: title)
            )
        }
    }

    private func timePickerRow(label: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            DatePicker(
                "",
                selection: selection,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .controlSize(.small)
#if os(iOS)
            .scaleEffect(0.85, anchor: .leading)
            .frame(height: 24)
#endif
            .environment(\.locale, timePickerLocale)
        }
    }

    private func save() {
        guard !hasInvalidSelectedTime else {
            validationMessage = localized("終了時刻は開始時刻以降にしてください。")
            return
        }

        let definitions = titles.compactMap { title -> ShiftDefinition? in
            guard selectedTitles.contains(title), let draft = timeDrafts[title] else { return nil }
            return ShiftDefinition(
                title: title,
                startMinutes: draft.startMinutes,
                endMinutes: draft.endMinutes
            )
        }
        onComplete(selectedTitles, definitions)
        dismiss()
    }

    private var hasInvalidSelectedTime: Bool {
        selectedTitles.contains { title in
            guard let draft = timeDrafts[title] else { return false }
            return draft.endMinutes < draft.startMinutes
        }
    }

    private func selectionBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { selectedTitles.contains(title) },
            set: { isSelected in
                if isSelected {
                    selectedTitles.insert(title)
                } else {
                    selectedTitles.remove(title)
                }
            }
        )
    }

    private func startDateBinding(for title: String) -> Binding<Date> {
        Binding(
            get: { date(from: timeDrafts[title]?.startMinutes ?? 510) },
            set: { date in
                timeDrafts[title, default: MissingShiftTimeDraft(startMinutes: 510, endMinutes: 1050)].startMinutes = minutes(from: date)
            }
        )
    }

    private func endDateBinding(for title: String) -> Binding<Date> {
        Binding(
            get: { date(from: timeDrafts[title]?.endMinutes ?? 1050) },
            set: { date in
                timeDrafts[title, default: MissingShiftTimeDraft(startMinutes: 510, endMinutes: 1050)].endMinutes = minutes(from: date)
            }
        )
    }

    private func date(from minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct ShiftDefinitionRegistrationView: View {
    let locale: Locale
    let onSave: (String, Int, Int) -> Void
    let isEditing: Bool

    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
#endif
    @State private var title = ""
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var validationMessage: String?

    init(
        locale: Locale,
        initialDefinition: ShiftDefinition? = nil,
        onSave: @escaping (String, Int, Int) -> Void
    ) {
        self.locale = locale
        self.onSave = onSave
        isEditing = initialDefinition != nil
        _title = State(initialValue: initialDefinition?.title ?? "")
        _startDate = State(initialValue: Self.date(from: initialDefinition?.startMinutes ?? 510))
        _endDate = State(initialValue: Self.date(from: initialDefinition?.endMinutes ?? 1050))
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var timePickerLocale: Locale {
        locale.identifier.hasPrefix("ja")
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_GB")
    }

    private var isValidationAlertPresented: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { isPresented in
                if !isPresented {
                    validationMessage = nil
                }
            }
        )
    }

#if os(iOS)
    private var registrationScreenBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .systemGroupedBackground)
    }

    private var registrationSectionBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }
#endif

    private func saveDefinition() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            validationMessage = localized("イベントタイトルを入力してください。")
            return
        }

        let startMinutes = Self.minutes(from: startDate)
        let endMinutes = Self.minutes(from: endDate)
        guard endMinutes >= startMinutes else {
            validationMessage = localized("終了時刻は開始時刻以降にしてください。")
            return
        }

        onSave(
            trimmedTitle,
            startMinutes,
            endMinutes
        )
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized(isEditing ? "イベントを編集" : "イベントを登録"))
                        .font(.title.bold())

                    Text(localized(isEditing ? "イベントタイトルと時間を編集します。" : "イベントタイトルと時間を保存します。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

#if os(macOS)
                Button(localized("保存")) {
                    saveDefinition()
                }
                .buttonStyle(.borderedProminent)
#endif
            }
            .padding(24)

            Divider()

#if os(macOS)
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("イベントタイトル"))
                    .font(.headline)

                TextField(localized("タイトル"), text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                Text(localized("開始時間と終了時間"))
                    .font(.headline)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    DatePicker(
                        localized("開始"),
                        selection: $startDate,
                        displayedComponents: .hourAndMinute
                    )
                    .environment(\.locale, timePickerLocale)

                    Text("-")
                        .foregroundStyle(.secondary)

                    DatePicker(
                        localized("終了"),
                        selection: $endDate,
                        displayedComponents: .hourAndMinute
                    )
                    .environment(\.locale, timePickerLocale)
                }
            }
            .padding(24)
#else
            Form {
                Section {
                    TextField(localized("タイトル"), text: $title, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .padding(16)
                        .background(
                            registrationSectionBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text(localized("イベントタイトル"))
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localized("開始"))
                            Spacer()
                            DatePicker(
                                "",
                                selection: $startDate,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .environment(\.locale, timePickerLocale)
                        }

                        Divider()

                        HStack {
                            Text(localized("終了"))
                            Spacer()
                            DatePicker(
                                "",
                                selection: $endDate,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .environment(\.locale, timePickerLocale)
                        }
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Text(localized("開始時間と終了時間"))
                }

                Section {
                    VStack {
                        Button {
                            saveDefinition()
                        } label: {
                            Text(localized("保存"))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(24)
#endif
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        .frame(width: 520, height: 360)
#endif
#if os(iOS)
        .background(
            registrationScreenBackground,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
#endif
        .environment(\.locale, locale)
        .alert(
            Text(localized("保存できません")),
            isPresented: isValidationAlertPresented
        ) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private static func date(from minutes: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                year: 2000,
                month: 1,
                day: 1,
                hour: minutes / 60,
                minute: minutes % 60
            )
        ) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func minutes(from date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

struct ShiftDefinitionSettingsView: View {
    @Binding var definitions: [ShiftDefinition]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var isRegistrationPresented = false
    @State private var editingDefinition: ShiftDefinition?
    @State private var isInvalidTimeAlertPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(macOS)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("イベント管理")
                        .font(.title.bold())

//                    Text("勤務タイトルと時間を保存します。")
//                        .font(.callout)
//                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isRegistrationPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(ShiftHubLocalization.string("追加", locale: locale))
                .help(ShiftHubLocalization.string("追加", locale: locale))
                .padding(.trailing)

#if os(macOS)
                Button("完了") {
                    if definitions.contains(where: { $0.endMinutes < $0.startMinutes }) {
                        isInvalidTimeAlertPresented = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
#endif
            }
            .padding(24)

            Divider()
#endif

            VStack(alignment: .leading, spacing: 12) {
                if definitions.isEmpty {
                    ContentUnavailableView(
                        "イベント設定がありません",
                        systemImage: "clock.badge.questionmark",
                        description: Text("追加ボタンからイベントタイトルと時間を登録してください。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    List {
                        ForEach($definitions) { $definition in
                            ShiftDefinitionRowView(
                                definition: $definition,
                                editAction: {
                                    editingDefinition = definition
                                },
                                deleteAction: {
                                    definitions.removeAll { $0.id == definition.id }
                                }
                            )
#if os(iOS)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingDefinition = definition
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .tint(.blue)
                                .accessibilityLabel(
                                    ShiftHubLocalization.string("編集", locale: locale)
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    definitions.removeAll { $0.id == definition.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(
                                    ShiftHubLocalization.string("削除", locale: locale)
                                )
                            }
#else
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
#endif
                        }
                        .onMove(perform: moveDefinitions)
                    }
                    .listStyle(.plain)
                }
            }
#if os(iOS)
            .padding(.horizontal, 0)
#else
            .padding(24)
#endif

        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("イベント管理")
        .navigationBarTitleDisplayMode(.inline)
#else
        .frame(minWidth: 680, minHeight: 460)
#endif
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isRegistrationPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(ShiftHubLocalization.string("追加", locale: locale))
                .help(ShiftHubLocalization.string("追加", locale: locale))
            }
        }
#endif
        .sheet(isPresented: $isRegistrationPresented) {
            ShiftDefinitionRegistrationView(locale: locale) { title, startMinutes, endMinutes in
                definitions.append(
                    ShiftDefinition(
                        title: title,
                        startMinutes: startMinutes,
                        endMinutes: endMinutes
                    )
                )
            }
        }
        .sheet(item: $editingDefinition) { definition in
            ShiftDefinitionRegistrationView(
                locale: locale,
                initialDefinition: definition
            ) { title, startMinutes, endMinutes in
                guard let index = definitions.firstIndex(where: { $0.id == definition.id }) else {
                    return
                }
                definitions[index].title = title
                definitions[index].startMinutes = startMinutes
                definitions[index].endMinutes = endMinutes
            }
        }
        .alert("保存できません", isPresented: $isInvalidTimeAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("終了時刻は開始時刻以降にしてください。")
        }
    }

    private func moveDefinitions(from source: IndexSet, to destination: Int) {
        definitions.move(fromOffsets: source, toOffset: destination)
    }
}

struct CalendarSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("calendarDestination") private var calendarDestination = CalendarDestination.apple.rawValue
    @AppStorage("appleCalendarIdentifier") private var appleCalendarIdentifier = ""
    @AppStorage("appleCalendarName") private var appleCalendarName = ""
    @AppStorage("appleRestEventTitle") private var appleRestEventTitle = "休"
    @AppStorage("googleCalendarID") private var googleCalendarID = "primary"
    @AppStorage("googleCalendarName") private var googleCalendarName = ""
    @AppStorage("googleRestEventTitle") private var googleRestEventTitle = "休"
    @AppStorage("googleShowJapaneseHolidays") private var googleShowJapaneseHolidays = false
    @AppStorage("notionDataSourceID") private var notionDataSourceID = ""
    @AppStorage("notionDatabaseName") private var notionDatabaseName = ""
    @AppStorage("notionTitleProperty") private var notionTitleProperty = "tasks"
    @AppStorage("notionDateProperty") private var notionDateProperty = "due date"
    @AppStorage("notionTagProperty") private var notionTagProperty = "tag"
    @AppStorage("notionTagValue") private var notionTagValue = "shift"
    @AppStorage("notionRestEventTitle") private var notionRestEventTitle = "休"
    @StateObject private var appleCalendarProvider = AppleCalendarProvider()
    @StateObject private var googleCalendarProvider = GoogleCalendarProvider()
    @State private var notionToken = ""
    @State private var notionProperties: [NotionPropertyOption] = []
    @State private var notionPropertyMessage = ""
    @State private var isLoadingNotionProperties = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(macOS)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("カレンダー設定")
                        .font(.title.bold())

                    Text("イベント情報の登録先を設定します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

#if os(macOS)
                Button("完了") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
#endif
            }
            .padding(24)

            Divider()
#endif

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    calendarSection("登録先カレンダー", systemImage: "paperplane") {
                        Picker("登録先", selection: $calendarDestination) {
                            ForEach(CalendarDestination.allCases) { destination in
                                Text(destination.title)
                                    .tag(destination.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("ここで選択したカレンダーを、イベントの登録先として使用します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                    case .apple:
                        calendarSection("Appleカレンダー", systemImage: "apple.logo") {
                            Button {
                                appleCalendarProvider.loadCalendars()
                            } label: {
                                Label("カレンダー一覧を取得", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(appleCalendarProvider.isLoading)

                            if appleCalendarProvider.isLoading {
                                ProgressView("取得中です...")
                                    .controlSize(.small)
                            }

                            if !appleCalendarProvider.calendars.isEmpty {
                                Picker("登録先カレンダー", selection: $appleCalendarIdentifier) {
                                    Text("デフォルトカレンダー")
                                        .tag("")

                                    ForEach(appleCalendarProvider.calendars) { calendar in
                                        Text(calendar.displayName(for: locale))
                                        .tag(calendar.id)
                                    }
                                }

                            }

                            if appleCalendarIdentifier.isEmpty {
                                Text("現在の登録先: デフォルトカレンダー")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if let selectedCalendar = appleCalendarProvider.calendars.first(where: { $0.id == appleCalendarIdentifier }) {
                                Text("現在の登録先: \(selectedCalendar.displayName(for: locale))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("保存されている登録先カレンダーを確認できません。もう一度一覧を取得してください。")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }

                            if !appleCalendarProvider.message.isEmpty {
                                Text(appleCalendarProvider.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    case .google:
                        calendarSection("Googleカレンダー", systemImage: "g.circle") {
                            HStack(spacing: 10) {
                                Button {
                                    googleCalendarProvider.signIn()
                                } label: {
                                    Label(
                                        googleCalendarProvider.isAuthorized ? "Googleに再ログイン" : "Googleにログイン",
                                        systemImage: "person.crop.circle.badge.checkmark"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(googleCalendarProvider.isAuthorizing)

                                if googleCalendarProvider.isAuthorized {
                                    Label("接続済み", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }

                            if googleCalendarProvider.isAuthorizing {
                                ProgressView("ブラウザでGoogleログインを待っています...")
                                    .controlSize(.small)
                            }

                            if googleCalendarProvider.isAuthorized {
                                Button {
                                    googleCalendarProvider.loadCalendars()
                                } label: {
                                    Label("カレンダー一覧を取得", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .disabled(googleCalendarProvider.isLoading)
                            }

                            if googleCalendarProvider.isLoading {
                                ProgressView("取得中です...")
                                    .controlSize(.small)
                            }

                            if !googleCalendarProvider.calendars.isEmpty {
                                Picker("登録先カレンダー", selection: $googleCalendarID) {
                                    ForEach(googleCalendarProvider.calendars) { calendar in
                                        Text(calendar.displayName(for: locale))
                                            .tag(calendar.id)
                                    }
                                }
                            }

                            if let selectedCalendar = googleCalendarProvider.calendars.first(where: {
                                $0.id == googleCalendarID
                            }) {
                                Text("現在の登録先: \(selectedCalendar.displayName(for: locale))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if googleCalendarProvider.isAuthorized {
                                Text("カレンダー一覧を取得して登録先を選択してください。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            if googleCalendarProvider.japaneseHolidayCalendarID != nil {
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle("日本の祝日を表示", isOn: $googleShowJapaneseHolidays)
                                    Text("Googleカレンダーの「日本の祝日」を、登録先と一緒に表示します。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !googleCalendarProvider.message.isEmpty {
                                Text(googleCalendarProvider.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Googleにログインしてカレンダーへのアクセスを許可し、登録先を選択します。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                    case .notion:
                        calendarSection("Notion DB", systemImage: "square.grid.2x2") {
                            HStack(spacing: 8) {
                                Text("Bearer")
                                    .foregroundStyle(.secondary)

                                SecureField("ntn_から始まるトークン", text: $notionToken)
                                    .textFieldStyle(.roundedBorder)
                            }

                            TextField("データベースID", text: $notionDataSourceID)
                                .textFieldStyle(.roundedBorder)

                            if !notionDatabaseName.isEmpty {
                                Label("接続先: \(notionDatabaseName)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }

                            if isLoadingNotionProperties {
                                ProgressView("Notionの列を取得中です...")
                                    .controlSize(.small)
                            }

                            if !notionProperties.isEmpty {
                                Text("取得した列から選択")
                                    .font(.callout.weight(.semibold))

                                if !notionProperties.filter({ $0.type == "title" }).isEmpty {
                                    Picker("タイトル列", selection: $notionTitleProperty) {
                                        ForEach(notionProperties.filter { $0.type == "title" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }
                                }

                                if !notionProperties.filter({ $0.type == "date" }).isEmpty {
                                    Picker("日付列", selection: $notionDateProperty) {
                                        ForEach(notionProperties.filter { $0.type == "date" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }
                                }

                                if !notionProperties.filter({ $0.type == "multi_select" }).isEmpty {
                                    Picker("タグ列", selection: $notionTagProperty) {
                                        ForEach(notionProperties.filter { $0.type == "multi_select" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }

                                    if let selectedTagProperty = notionProperties.first(where: {
                                        $0.name == notionTagProperty && $0.type == "multi_select"
                                    }), !selectedTagProperty.options.isEmpty {
                                        Picker("タグ値を選択", selection: $notionTagValue) {
                                            ForEach(selectedTagProperty.options, id: \.self) { option in
                                                Text(option)
                                                    .tag(option)
                                            }
                                        }
                                    }
                                }
                            }

                            if !notionPropertyMessage.isEmpty {
                                Text(notionPropertyMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Text("データベースID、列名、タグ値はNotion側の設定に合わせて入力してください。Bearer、プロパティの種類、JSON構造はアプリが補完します。対象データベースをNotionの接続に共有し、ページ追加権限を付与してください。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    calendarSection("休の登録名", systemImage: "textformat") {
                        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                        case .apple:
                            restEventTitleField($appleRestEventTitle)
                        case .google:
                            restEventTitleField($googleRestEventTitle)
                        case .notion:
                            restEventTitleField($notionRestEventTitle)
                        }
                    }

                    calendarSection("登録ルール", systemImage: "checklist") {
                        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                        case .apple:
                            ruleRow("休", "時間を指定しない終日イベントとして登録")
                            ruleRow("イベント", "開始・終了時刻を指定して登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        case .notion:
                            ruleRow("休", "00:00〜23:59の時間付きデータとして登録")
                            ruleRow("イベント", "日付プロパティに開始・終了時刻を登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        case .google:
                            ruleRow("休", "時間を指定しない終日イベントとして登録")
                            ruleRow("イベント", "開始・終了時刻を指定して登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        }
                    }
                }
                .padding(24)
            }
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("カレンダー設定")
        .navigationBarTitleDisplayMode(.inline)
#else
        .frame(minWidth: 680, minHeight: 620)
#endif
        .onAppear {
            appleCalendarProvider.setLocaleIdentifier(locale.identifier)
            googleCalendarProvider.setLocaleIdentifier(locale.identifier)
            appleCalendarProvider.loadCalendarsIfAuthorized()
            googleCalendarProvider.loadSavedState()
            updateAppleCalendarName()
            updateGoogleCalendarName()
            if googleCalendarProvider.isAuthorized {
                googleCalendarProvider.loadCalendars()
            }
            notionToken = KeychainStore.string(for: "notion-access-token") ?? ""

            if notionTitleProperty == "Name" {
                notionTitleProperty = "tasks"
            }
            if notionDateProperty == "Date" {
                notionDateProperty = "due date"
            }
        }
        .onChange(of: calendarDestination) {
            if calendarDestination == CalendarDestination.apple.rawValue {
                appleCalendarProvider.loadCalendarsIfAuthorized()
            }
            if calendarDestination == CalendarDestination.google.rawValue {
                googleCalendarProvider.loadSavedState()
            }
        }
        .onChange(of: locale.identifier) {
            appleCalendarProvider.setLocaleIdentifier(locale.identifier)
            googleCalendarProvider.setLocaleIdentifier(locale.identifier)
        }
        .onChange(of: appleCalendarIdentifier) {
            updateAppleCalendarName()
        }
        .onChange(of: appleCalendarProvider.calendars) {
            reconcileAppleCalendarSelection()
            updateAppleCalendarName()
        }
        .onChange(of: googleCalendarID) {
            updateGoogleCalendarName()
        }
        .onChange(of: googleCalendarProvider.calendars) {
            updateGoogleCalendarName()
        }
        .onChange(of: notionToken) {
            KeychainStore.set(notionToken, for: "notion-access-token")
        }
        .onChange(of: calendarSettingsSyncKey) {
            NotificationCenter.default.post(name: .shiftHubSettingsDidChange, object: nil)
        }
        .task(id: notionDiscoveryKey) {
            await discoverNotionProperties()
        }
        .onDisappear {
            NotificationCenter.default.post(name: .shiftHubSettingsDidChange, object: nil)
        }
    }

    private func restEventTitleField(_ title: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("休 →")
                .foregroundStyle(.secondary)
            TextField("登録名（例: off）", text: title)
                .textFieldStyle(.roundedBorder)
        }
        .help("勤務表の「休」を、この名前で登録します。")
    }

    private func calendarSection<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleRow(_ name: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.body.weight(.semibold))

            Text(detail)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private func updateAppleCalendarName() {
        let name: String
        if appleCalendarIdentifier.isEmpty {
            name = appleCalendarProvider.defaultCalendarName
        } else {
            name = appleCalendarProvider.calendars.first(where: {
                $0.id == appleCalendarIdentifier
            })?.displayName(for: locale) ?? ""
        }

        appleCalendarName = name
    }

    private func reconcileAppleCalendarSelection() {
        guard !appleCalendarIdentifier.isEmpty,
              !appleCalendarProvider.isLoading,
              !appleCalendarProvider.calendars.isEmpty,
              !appleCalendarProvider.calendars.contains(where: {
                  $0.id == appleCalendarIdentifier
              }) else {
            return
        }

        appleCalendarIdentifier = ""
        updateAppleCalendarName()
    }

    private func updateGoogleCalendarName() {
        googleCalendarName = googleCalendarProvider.calendars.first(where: {
            $0.id == googleCalendarID
        })?.displayName(for: locale) ?? ""
    }

    private var notionDiscoveryKey: String {
        "\(notionToken)|\(notionDataSourceID)"
    }

    private var calendarSettingsSyncKey: [String] {
        [
            calendarDestination,
            appleCalendarIdentifier,
            appleRestEventTitle,
            googleCalendarID,
            googleRestEventTitle,
            notionDataSourceID,
            notionTitleProperty,
            notionDateProperty,
            notionTagProperty,
            notionTagValue,
            notionRestEventTitle
        ]
    }

    private func discoverNotionProperties() async {
        let token = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseID = notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard token.count >= 8, databaseID.count >= 8 else {
            notionDatabaseName = ""
            notionProperties = []
            notionPropertyMessage = ShiftHubLocalization.string(
                "トークンとデータベースIDを入力すると、列を自動取得します。",
                locale: locale
            )
            return
        }

        isLoadingNotionProperties = true
        notionDatabaseName = ""
        notionPropertyMessage = ""

        do {
            try await Task.sleep(for: .milliseconds(600))
            try Task.checkCancellation()
            let schema = try await NotionSchemaClient().fetchSchema(
                token: token,
                databaseID: databaseID,
                localeIdentifier: locale.identifier
            )
            try Task.checkCancellation()
            notionDatabaseName = schema.title
            notionProperties = schema.properties
            notionPropertyMessage = schema.properties.isEmpty
                ? ShiftHubLocalization.string(
                    "取得できる列がありませんでした。Notionの接続権限を確認してください。",
                    locale: locale
                )
                : ShiftHubLocalization.format(
                    "%@個の列を取得しました。",
                    locale: locale,
                    arguments: String(schema.properties.count)
                )
        } catch is CancellationError {
            return
        } catch {
            notionProperties = []
            notionPropertyMessage = ShiftHubLocalization.format(
                "列を取得できませんでした: %@",
                locale: locale,
                arguments: ShiftHubLocalization.localizedErrorDescription(error, locale: locale)
            )
        }

        isLoadingNotionProperties = false
    }
}
