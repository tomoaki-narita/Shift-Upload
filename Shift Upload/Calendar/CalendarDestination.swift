import SwiftUI

enum CalendarDestination: String, CaseIterable, Identifiable, Equatable {
    case apple
    case google
    case notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return "Apple"
        case .google:
            return "Google"
        case .notion:
            return "Notion DB"
        }
    }

    var registrationTitleKey: LocalizedStringKey {
        switch self {
        case .apple:
            return "Appleカレンダーへ登録"
        case .google:
            return "Googleカレンダーへ登録"
        case .notion:
            return "Notion DBへ登録"
        }
    }
}
