import Foundation
import SwiftUI

// Registration sheets and preview UI.
private struct CalHubMetadataTextFieldStyle: ViewModifier {
    let lineLimit: ClosedRange<Int>

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .lineLimit(lineLimit)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
#if os(iOS)
            .background(
                Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
#else
            .frame(maxWidth: .infinity)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
#endif
    }
}

private extension View {
    func calHubMetadataTextFieldStyle(lineLimit: ClosedRange<Int> = 1...4) -> some View {
        modifier(CalHubMetadataTextFieldStyle(lineLimit: lineLimit))
    }
}

private struct CalHubSegmentLayout: Layout {
    let selectedIndex: Int?

    init(selectedIndex: Int?) {
        self.selectedIndex = selectedIndex
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
        let naturalHeight = sizes.map(\.height).max() ?? 24

        return CGSize(
            width: proposal.width ?? naturalWidth,
            height: proposal.height ?? naturalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let buttonSubviews = subviews.dropFirst()
        guard !buttonSubviews.isEmpty else { return }

        let sizes = buttonSubviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
        let extraWidth = max(bounds.width - naturalWidth, 0) / CGFloat(buttonSubviews.count)
        let widths = sizes.map { $0.width + extraWidth }

        if let selectedIndex,
           widths.indices.contains(selectedIndex) {
            let selectedX = widths.prefix(selectedIndex).reduce(CGFloat.zero, +)
            subviews[0].place(
                at: CGPoint(x: bounds.minX + selectedX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(
                    width: widths[selectedIndex],
                    height: bounds.height
                )
            )
        }

        var x = bounds.minX

        for (index, subview) in buttonSubviews.enumerated() {
            let width = widths[index]
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}

struct CalHubSegmentedControl: View {
    let options: [String]
    let animationDuration: Double
    @Binding var selection: String

    init(
        options: [String],
        selection: Binding<String>,
        animationDuration: Double = 0.16
    ) {
        self.options = options
        self.animationDuration = animationDuration
        _selection = selection
    }

    var body: some View {
        GeometryReader { proxy in
            CalHubSegmentLayout(selectedIndex: options.firstIndex(of: selection)) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .allowsHitTesting(false)

                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button {
                        withAnimation(.easeOut(duration: animationDuration)) {
                            selection = option
                        }
                    } label: {
                        Text(option.isEmpty ? "未選択" : option)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .frame(width: max(proxy.size.width - 6, 0), height: 24, alignment: .leading)
            .animation(.easeOut(duration: animationDuration), value: selection)
            .padding(3)
        }
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(Color.secondary.opacity(0.22), in: Capsule())
    }
}

struct SingleShiftRegistrationView: View {
    let definitions: [ShiftDefinition]
    let onRegister: (YearMonth, Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var selectedDay: Int
    @State private var selectedTitle: String

    init(
        initialYearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        onRegister: @escaping (YearMonth, Int, String) -> Void
    ) {
        let initial = initialYearMonth ?? .current
        self.definitions = definitions.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.onRegister = onRegister
        _selectedYear = State(initialValue: initial.year)
        _selectedMonth = State(initialValue: initial.month)
        _selectedDay = State(initialValue: 1)
        _selectedTitle = State(initialValue: definitions.first(where: {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.title ?? "休")
    }

    private var selectedYearMonth: YearMonth {
        YearMonth(year: selectedYear, month: selectedMonth)
    }

    private var yearOptions: [Int] {
        let currentYear = YearMonth.current.year
        let range = Array((currentYear - 10)...(currentYear + 10))
        return Array(Set(range + [selectedYear])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("日付ごとに登録")
                        .font(.title.bold())

                    Text("登録する日付とイベントを選択します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("キャンセル") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("登録") {
                    onRegister(selectedYearMonth, selectedDay, selectedTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            Form {
                HStack {
                    Picker("年", selection: $selectedYear) {
                        ForEach(yearOptions, id: \.self) { year in
                            Text(ShiftHubLocalization.yearText(year, locale: locale)).tag(year)
                        }
                    }

                    Picker("月", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { month in
                            Text(ShiftHubLocalization.monthText(month, locale: locale)).tag(month)
                        }
                    }
                }

                Picker("日付", selection: $selectedDay) {
                    ForEach(1...selectedYearMonth.numberOfDays, id: \.self) { day in
                        Text("\(selectedMonth)/\(day)")
                            .tag(day)
                    }
                }

                Picker("イベント", selection: $selectedTitle) {
                    Text("休（終日）")
                        .tag("休")

                    ForEach(definitions) { definition in
                        Text("\(definition.title)  \(definition.timeRangeText)")
                            .tag(definition.title)
                    }
                }

                if selectedTitle == "休" {
                    Text("終日イベントとして登録します。")
                        .foregroundStyle(.secondary)
                } else if let definition = definitions.first(where: { $0.title == selectedTitle }) {
                    Text("登録時間: \(definition.timeRangeText)")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(24)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 520, height: 360)
#endif
        .onChange(of: selectedYear) {
            selectedDay = min(selectedDay, selectedYearMonth.numberOfDays)
        }
        .onChange(of: selectedMonth) {
            selectedDay = min(selectedDay, selectedYearMonth.numberOfDays)
        }
    }
}

struct DateTimeEventRegistrationView: View {
    let initialStartDate: Date
    let locale: Locale
    let initialTitle: String
    let initialEndDate: Date?
    let initialIsAllDay: Bool
    let initialMetadata: CalendarEventMetadata
    let metadataFieldLabels: CalendarEventMetadataFieldLabels
    let isEditing: Bool
    let onRegister: (CalendarEventDraft) -> Void

    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
#endif
    @State private var title = ""
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay = false
    @State private var notes = ""
    @State private var location = ""
    @State private var url = ""
    @State private var tagValue = ""
    @State private var propertyValues: [String: String] = [:]
    @State private var validationMessage: String?

    init(
        initialStartDate: Date,
        locale: Locale,
        initialTitle: String = "",
        initialEndDate: Date? = nil,
        initialIsAllDay: Bool = false,
        initialMetadata: CalendarEventMetadata = .empty,
        metadataFieldLabels: CalendarEventMetadataFieldLabels,
        isEditing: Bool = false,
        onRegister: @escaping (CalendarEventDraft) -> Void
    ) {
        self.initialStartDate = initialStartDate
        self.locale = locale
        self.initialTitle = initialTitle
        self.initialEndDate = initialEndDate
        self.initialIsAllDay = initialIsAllDay
        self.initialMetadata = initialMetadata
        self.metadataFieldLabels = metadataFieldLabels
        self.isEditing = isEditing
        self.onRegister = onRegister
        _title = State(initialValue: initialTitle)
        _startDate = State(initialValue: initialStartDate)
        _endDate = State(
            initialValue: initialEndDate
                ?? Calendar.current.date(byAdding: .hour, value: 1, to: initialStartDate)
                ?? initialStartDate
        )
        _isAllDay = State(initialValue: initialIsAllDay)
        _notes = State(initialValue: initialMetadata.notes)
        _location = State(initialValue: initialMetadata.location)
        _url = State(initialValue: initialMetadata.url)
        _tagValue = State(initialValue: initialMetadata.tagValue.isEmpty
            ? metadataFieldLabels.tagDefaultValue
            : initialMetadata.tagValue)
        var propertyValues = metadataFieldLabels.defaultPropertyValues
        for (name, value) in initialMetadata.propertyValues where !value.isEmpty {
            propertyValues[name] = value
        }
        _propertyValues = State(initialValue: propertyValues)
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

    private func registerEvent() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            validationMessage = localized("イベントタイトルを入力してください。")
            return
        }

        guard endDate >= startDate else {
            validationMessage = localized("終了日時は開始日時以降にしてください。")
            return
        }

        let metadata = CalendarEventMetadata(
            notes: metadataFieldLabels.notesIsAvailable ? notes : "",
            location: metadataFieldLabels.locationIsAvailable ? location : "",
            url: metadataFieldLabels.urlIsAvailable ? url : "",
            tagValue: metadataFieldLabels.tagIsAvailable ? tagValue : "",
            propertyValues: propertyValues
        ).normalized
        if !metadata.url.isEmpty {
            guard let components = URLComponents(string: metadata.url),
                  (components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https"),
                  components.host?.isEmpty == false else {
                validationMessage = localized("URLを確認してください。")
                return
            }
        }
        for property in metadataFieldLabels.additionalProperties where property.type == "url" {
            let value = metadata.propertyValues[property.name] ?? ""
            guard value.isEmpty || isValidMetadataURL(value) else {
                validationMessage = localized("URLを確認してください。")
                return
            }
        }

        let calendar = Calendar.current
        let normalizedStartDate = isAllDay ? calendar.startOfDay(for: startDate) : startDate
        let normalizedEndDate = isAllDay ? calendar.startOfDay(for: endDate) : endDate
        onRegister(
            CalendarEventDraft(
                title: trimmedTitle,
                startDate: normalizedStartDate,
                endDate: normalizedEndDate,
                isAllDay: isAllDay,
                metadata: metadata
            )
        )
        dismiss()
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var timePickerLocale: Locale {
        locale.identifier.hasPrefix("ja")
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_GB")
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

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized(isEditing ? "イベントを編集" : "イベントを登録"))
                        .font(.title.bold())

                    Text(localized(
                        isEditing
                            ? "イベントタイトルと時間を編集します。"
                            : "タイトルと日時を指定して登録します。"
                    ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

#if os(macOS)
                Button(localized(isEditing ? "保存" : "登録")) {
                    registerEvent()
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

                Text(localized("日時"))
                    .font(.headline)
                    .padding(.top, 8)

                Toggle(localized("終日"), isOn: $isAllDay)

                HStack(alignment: .center, spacing: 8) {
                    DatePicker(
                        localized("開始"),
                        selection: $startDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .environment(\.locale, timePickerLocale)
                    Text("-")
                        .foregroundStyle(.secondary)
                    DatePicker(
                        localized("終了"),
                        selection: $endDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .environment(\.locale, timePickerLocale)
                }

                if endDate < startDate {
                    Text(localized("終了日時は開始日時以降にしてください。"))
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if metadataFieldLabels.hasAvailableFields {
                    Text(localized("詳細"))
                        .font(.headline)

                    eventMetadataFields
                        .padding(16)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
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
                        Toggle(localized("終日"), isOn: $isAllDay)

                        Divider()

                        DatePicker(
                            localized("開始"),
                            selection: $startDate,
                            displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .environment(\.locale, timePickerLocale)

                        Divider()

                        DatePicker(
                            localized("終了"),
                            selection: $endDate,
                            displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .environment(\.locale, timePickerLocale)

                        if endDate < startDate {
                            Text(localized("終了日時は開始日時以降にしてください。"))
                                .font(.callout)
                                .foregroundStyle(.red)
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
                    Text(localized("日時"))
                }

                Section {
                    if metadataFieldLabels.hasAvailableFields {
                        eventMetadataFields
                        .padding(16)
                        .background(
                            registrationSectionBackground,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(localized("詳細"))
                }

                Section {
                    VStack {
                        Button {
                            registerEvent()
                        } label: {
                            Text(localized(isEditing ? "保存" : "登録"))
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
        .alert(
            Text(localized("保存できません")),
            isPresented: isValidationAlertPresented
        ) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 560, height: 420)
#endif
#if os(iOS)
        .background(
            registrationScreenBackground,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
#endif
        .environment(\.locale, locale)
        .onChange(of: isAllDay) {
            let calendar = Calendar.current
            if isAllDay {
                startDate = calendar.startOfDay(for: startDate)
                endDate = calendar.startOfDay(for: endDate)
            }
        }
    }

    @ViewBuilder
    private var eventMetadataFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if metadataFieldLabels.tagIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.tag)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.tag, text: $tagValue, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...2)
                }
            }

            if metadataFieldLabels.locationIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.location, text: $location, axis: .vertical)
                        .calHubMetadataTextFieldStyle()
                }
            }

            if metadataFieldLabels.urlIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.url)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.url, text: $url, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...3)
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                }
            }

            if metadataFieldLabels.notesIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.notes, text: $notes, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...6)
                }
            }

            dynamicMetadataFields
        }
    }

    @ViewBuilder
    private var dynamicMetadataFields: some View {
        ForEach(metadataFieldLabels.additionalProperties) { property in
            VStack(alignment: .leading, spacing: 6) {
                Text(property.displayName(for: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if ["multi_select", "select"].contains(property.type) {
                    if property.options.isEmpty {
                        Text("選択肢がありません")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        CalHubSegmentedControl(
                            options: [""] + property.options,
                            selection: metadataPropertyBinding(for: property)
                        )
                    }
                } else {
                    TextField(property.displayName(for: locale), text: metadataPropertyBinding(for: property), axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: property.type == "url" ? 1...3 : 1...6)
#if os(iOS)
                        .keyboardType(property.type == "url" ? .URL : .default)
                        .textInputAutocapitalization(property.type == "url" ? .never : .sentences)
                        .autocorrectionDisabled(property.type == "url")
#endif
                }
            }
        }
    }

    private func metadataPropertyBinding(for property: NotionPropertyOption) -> Binding<String> {
        Binding(
            get: { propertyValues[property.name] ?? "" },
            set: { propertyValues[property.name] = $0 }
        )
    }

    private func isValidMetadataURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return (components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https")
            && components.host?.isEmpty == false
    }
}

struct ShiftSelectionView: View {
    let definitions: [ShiftDefinition]
    let tint: Color
    let locale: Locale
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        definitions: [ShiftDefinition],
        tint: Color = .accentColor,
        locale: Locale,
        onSelect: @escaping (String) -> Void
    ) {
        self.definitions = definitions
        self.tint = tint
        self.locale = locale
        self.onSelect = onSelect
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("イベントを選択"))
                        .font(.title2.bold())

                    Text(localized("登録するイベントをイベント設定から選択します。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    shiftSelectionRow(
                        title: "休",
                        detail: localized("終日"),
                        symbol: "moon.zzz.fill",
                        tint: .red
                    )

                    ForEach(definitions) { definition in
                        shiftSelectionRow(
                            title: definition.title,
                            detail: definition.timeRangeText,
                            symbol: "clock.fill",
                            tint: tint
                        )
                    }
                }
                .padding(20)
            }
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 460, height: 430)
#endif
    }

    private func shiftSelectionRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Button {
            onSelect(title)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: Circle())

                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 10)

                Text(detail)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.background.secondary.opacity(0.7), in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 52)
        }
        .buttonStyle(ShiftSelectionRowButtonStyle())
    }
}

struct RegistrationPreview: Identifiable {
    let id = UUID()
    let cells: [ExtractedShiftCell]
    let yearMonth: YearMonth
    let includeRest: Bool
    let destinationTitle: String
    let events: [RegistrationPreviewEvent]
    let excludedEvents: [RegistrationPreviewExcludedEvent]
    let skippedTitles: [String]
    let excludedCount: Int
    let invalidItems: [String]

    var canRegister: Bool {
        !events.isEmpty && invalidItems.isEmpty
    }
}

struct RegistrationPreviewExcludedEvent: Identifiable {
    let id = UUID()
    let yearMonth: YearMonth
    let day: Int?
    let rawDateText: String
    let title: String
    let startMinutes: Int?
    let endMinutes: Int?
    let reason: RegistrationPreviewExclusionReason
}

enum RegistrationPreviewExclusionReason {
    case invalidDate
    case emptyTitle
    case restDisabled
    case missingTitle
}

struct RegistrationPreviewEvent: Identifiable {
    let id = UUID()
    let yearMonth: YearMonth
    let day: Int
    let title: String
    let startMinutes: Int?
    let endMinutes: Int?
}

struct RegistrationPreviewDay: Identifiable {
    let yearMonth: YearMonth
    let day: Int
    let events: [RegistrationPreviewEvent]

    var id: String {
        "\(yearMonth.year)-\(yearMonth.month)-\(day)"
    }
}

struct RegistrationPreviewView: View {
    let preview: RegistrationPreview
    let locale: Locale
    let metadataFieldLabels: CalendarEventMetadataFieldLabels
    let onRegister: (RegistrationPreview, CalendarEventMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isExcludedEventsExpanded = false
    @State private var excludedEventsContentOpacity = 0.0
    @State private var excludedEventsAnimationID = 0
    @State private var notes = ""
    @State private var location = ""
    @State private var url = ""
    @State private var tagValue = ""
    @State private var propertyValues: [String: String] = [:]
    @State private var validationMessage: String?

    init(
        preview: RegistrationPreview,
        locale: Locale,
        metadataFieldLabels: CalendarEventMetadataFieldLabels,
        onRegister: @escaping (RegistrationPreview, CalendarEventMetadata) -> Void
    ) {
        self.preview = preview
        self.locale = locale
        self.metadataFieldLabels = metadataFieldLabels
        self.onRegister = onRegister
        _propertyValues = State(initialValue: metadataFieldLabels.defaultPropertyValues)
    }

    private var groupedEvents: [RegistrationPreviewDay] {
        let grouped = Dictionary(grouping: preview.events) { event in
            "\(event.yearMonth.year)-\(event.yearMonth.month)-\(event.day)"
        }

        return grouped.values.compactMap { events in
            guard let first = events.first else { return nil }
            return RegistrationPreviewDay(
                yearMonth: first.yearMonth,
                day: first.day,
                events: events.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            )
        }
        .sorted {
            if $0.yearMonth.year != $1.yearMonth.year {
                return $0.yearMonth.year < $1.yearMonth.year
            }
            if $0.yearMonth.month != $1.yearMonth.month {
                return $0.yearMonth.month < $1.yearMonth.month
            }
            return $0.day < $1.day
        }
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private func localized(_ key: String, arguments: CVarArg...) -> String {
        ShiftHubLocalization.format(key, locale: locale, arguments: arguments)
    }

    private func dateTitle(for day: RegistrationPreviewDay) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(
            year: day.yearMonth.year,
            month: day.yearMonth.month,
            day: day.day
        )) else {
            return "\(day.yearMonth.month)/\(day.day)"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = locale.identifier.hasPrefix("en")
            ? "MMM d (EEE)"
            : "M月d日（EEE）"
        return formatter.string(from: date)
    }

    private func timeText(for event: RegistrationPreviewEvent) -> String {
        guard let startMinutes = event.startMinutes,
              let endMinutes = event.endMinutes else {
            return localized("終日")
        }

        return "\(Self.minuteText(startMinutes))-\(Self.minuteText(endMinutes))"
    }

    private func register() {
        let metadata = CalendarEventMetadata(
            notes: metadataFieldLabels.notesIsAvailable ? notes : "",
            location: metadataFieldLabels.locationIsAvailable ? location : "",
            url: metadataFieldLabels.urlIsAvailable ? url : "",
            tagValue: metadataFieldLabels.tagIsAvailable ? tagValue : "",
            propertyValues: propertyValues
        ).normalized

        if !metadata.url.isEmpty {
            guard let components = URLComponents(string: metadata.url),
                  (components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https"),
                  components.host?.isEmpty == false else {
                validationMessage = localized("URLを確認してください。")
                return
            }
        }
        for property in metadataFieldLabels.additionalProperties where property.type == "url" {
            let value = metadata.propertyValues[property.name] ?? ""
            guard value.isEmpty || isValidMetadataURL(value) else {
                validationMessage = localized("URLを確認してください。")
                return
            }
        }

        onRegister(preview, metadata)
    }

    @ViewBuilder
    private var eventMetadataFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if metadataFieldLabels.tagIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.tag)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.tag, text: $tagValue, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...2)
                }
            }

            if metadataFieldLabels.locationIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.location, text: $location, axis: .vertical)
                        .calHubMetadataTextFieldStyle()
                }
            }

            if metadataFieldLabels.urlIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.url)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.url, text: $url, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...3)
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                }
            }

            if metadataFieldLabels.notesIsAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadataFieldLabels.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(metadataFieldLabels.notes, text: $notes, axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: 1...6)
                }
            }

            dynamicMetadataFields
        }
    }

    @ViewBuilder
    private var dynamicMetadataFields: some View {
        ForEach(metadataFieldLabels.additionalProperties) { property in
            VStack(alignment: .leading, spacing: 6) {
                Text(property.displayName(for: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if ["multi_select", "select"].contains(property.type) {
                    if property.options.isEmpty {
                        Text("選択肢がありません")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        CalHubSegmentedControl(
                            options: [""] + property.options,
                            selection: metadataPropertyBinding(for: property)
                        )
                    }
                } else {
                    TextField(property.displayName(for: locale), text: metadataPropertyBinding(for: property), axis: .vertical)
                        .calHubMetadataTextFieldStyle(lineLimit: property.type == "url" ? 1...3 : 1...6)
#if os(iOS)
                        .keyboardType(property.type == "url" ? .URL : .default)
                        .textInputAutocapitalization(property.type == "url" ? .never : .sentences)
                        .autocorrectionDisabled(property.type == "url")
#endif
                }
            }
        }
    }

    private func metadataPropertyBinding(for property: NotionPropertyOption) -> Binding<String> {
        Binding(
            get: { propertyValues[property.name] ?? "" },
            set: { propertyValues[property.name] = $0 }
        )
    }

    private func isValidMetadataURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return (components.scheme?.lowercased() == "http" || components.scheme?.lowercased() == "https")
            && components.host?.isEmpty == false
    }

    private static func minuteText(_ minutes: Int) -> String {
        let clampedMinutes = min(max(minutes, 0), 1_439)
        return String(format: "%d:%02d", clampedMinutes / 60, clampedMinutes % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("登録内容を確認"))
                        .font(.title.bold())

                    Text(localized("登録前に内容を確認してください。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(preview.destinationTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(localized("登録件数: %@", arguments: String(preview.events.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if metadataFieldLabels.hasAvailableFields {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(localized("詳細"))
                                .font(.headline)

                            eventMetadataFields
                                .padding(16)
                                .background(
                                    .background.secondary.opacity(0.32),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                        }
                    }

                    if !preview.invalidItems.isEmpty || !preview.skippedTitles.isEmpty || preview.excludedCount > 0 {
                        Button {
                            guard preview.excludedCount > 0 else { return }
                            toggleExcludedEvents()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localized("登録されないイベント"))
                                    .font(.headline)

                                if !preview.invalidItems.isEmpty {
                                    Text(localized(
                                        "時間設定を確認してください: %@",
                                        arguments: preview.invalidItems.joined(separator: ", ")
                                    ))
                                        .foregroundStyle(.red)
                                }

                                if !preview.skippedTitles.isEmpty {
                                    Text(localized(
                                        "未登録タイトル: %@",
                                        arguments: preview.skippedTitles.joined(separator: ", ")
                                    ))
                                    .foregroundStyle(.secondary)
                                }

                                if preview.excludedCount > 0 {
                                    HStack(spacing: 8) {
                                        Text(localized(
                                            "登録から除外されるイベント: %@件",
                                            arguments: String(preview.excludedCount)
                                        ))

                                        Spacer(minLength: 8)

                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                            .rotationEffect(.degrees(isExcludedEventsExpanded ? 90 : 0))
                                    }
                                    .foregroundStyle(.secondary)

                                    if isExcludedEventsExpanded {
                                        ExcludedRegistrationEventsListView(
                                            events: preview.excludedEvents,
                                            locale: locale
                                        )
                                        .opacity(excludedEventsContentOpacity)
                                    }
                                }
                            }
                            .font(.callout)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                .background.secondary.opacity(0.32),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()
                    }

                    if groupedEvents.isEmpty {
                        Text(localized("登録できるイベントがありません。"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(groupedEvents) { day in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(dateTitle(for: day))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 0) {
                                    ForEach(day.events) { event in
                                        HStack(spacing: 12) {
                                            Text(event.title)
                                                .lineLimit(2)

                                            Spacer(minLength: 12)

                                            Text(timeText(for: event))
                                                .font(.callout.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)

                                        if event.id != day.events.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .background(
                                    .background.secondary.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                        }
                    }

                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(localized("登録")) {
                    register()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!preview.canRegister)
            }
            .padding(20)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDragIndicator(.visible)
#else
        .frame(width: 560, height: 640)
#endif
        .environment(\.locale, locale)
        .onAppear {
            if tagValue.isEmpty {
                tagValue = metadataFieldLabels.tagDefaultValue
            }
        }
        .alert(
            Text(localized("保存できません")),
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private func toggleExcludedEvents() {
        excludedEventsAnimationID += 1
        let animationID = excludedEventsAnimationID
        let animation = Animation.easeInOut(duration: 0.12)

        if isExcludedEventsExpanded {
            withAnimation(animation) {
                excludedEventsContentOpacity = 0
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard animationID == excludedEventsAnimationID else { return }
                withAnimation(animation) {
                    isExcludedEventsExpanded = false
                }
            }
        } else {
            excludedEventsContentOpacity = 0
            withAnimation(animation) {
                isExcludedEventsExpanded = true
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard animationID == excludedEventsAnimationID else { return }
                withAnimation(animation) {
                    excludedEventsContentOpacity = 1
                }
            }
        }
    }
}

private struct ExcludedRegistrationEventsListView: View {
    let events: [RegistrationPreviewExcludedEvent]
    let locale: Locale

    private var sortedEvents: [RegistrationPreviewExcludedEvent] {
        events.sorted {
            let lhsDay = $0.day ?? Int.max
            let rhsDay = $1.day ?? Int.max
            if $0.yearMonth.year != $1.yearMonth.year {
                return $0.yearMonth.year < $1.yearMonth.year
            }
            if $0.yearMonth.month != $1.yearMonth.month {
                return $0.yearMonth.month < $1.yearMonth.month
            }
            if lhsDay != rhsDay {
                return lhsDay < rhsDay
            }
            if $0.rawDateText != $1.rawDateText {
                return $0.rawDateText < $1.rawDateText
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(sortedEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(dateTitle(for: event))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .lineLimit(2)

                            Text(reasonText(for: event))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Text(timeText(for: event))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(event.startMinutes == nil || event.endMinutes == nil ? .red : .secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .background.secondary.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }
        }
        .padding(.top, 2)
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private func dateTitle(for event: RegistrationPreviewExcludedEvent) -> String {
        guard let day = event.day else {
            return event.rawDateText.isEmpty ? localized("日付不明") : event.rawDateText
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(
            year: event.yearMonth.year,
            month: event.yearMonth.month,
            day: day
        )) else {
            return event.rawDateText
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = locale.identifier.hasPrefix("en")
            ? "MMM d (EEE)"
            : "M月d日（EEE）"
        return formatter.string(from: date)
    }

    private func timeText(for event: RegistrationPreviewExcludedEvent) -> String {
        guard let startMinutes = event.startMinutes,
              let endMinutes = event.endMinutes else {
            return localized("時間未設定")
        }

        return "\(Self.minuteText(startMinutes))-\(Self.minuteText(endMinutes))"
    }

    private func reasonText(for event: RegistrationPreviewExcludedEvent) -> String {
        switch event.reason {
        case .invalidDate:
            return localized("日付を判定できませんでした")
        case .emptyTitle:
            return localized("タイトルが空です")
        case .restDisabled:
            return localized("休の登録が無効です")
        case .missingTitle:
            return localized("イベント一覧に登録されていません")
        }
    }

    private static func minuteText(_ minutes: Int) -> String {
        let clampedMinutes = min(max(minutes, 0), 1_439)
        return String(format: "%d:%02d", clampedMinutes / 60, clampedMinutes % 60)
    }
}
