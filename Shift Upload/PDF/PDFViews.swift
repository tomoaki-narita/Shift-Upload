import Combine
import Foundation
import PDFKit
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SavedScheduleListView: View {
    let schedules: [StoredSchedule]
    let selectedScheduleID: UUID?
    let onSelect: (StoredSchedule) -> Void
    let onDelete: (StoredSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var previewSchedule: StoredSchedule?
#endif

    private var displayLocale: Locale {
        Locale(identifier: appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShiftHubLocalization.string("履歴", locale: displayLocale))
                        .font(.title2.bold())

                    Text(ShiftHubLocalization.string("保存した勤務表を選択して解析します。", locale: displayLocale))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    Text("\(schedules.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(ShiftHubLocalization.string("完了", locale: displayLocale)) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            if schedules.isEmpty {
                ContentUnavailableView(
                    ShiftHubLocalization.string("保存した勤務表がありません", locale: displayLocale),
                    systemImage: "folder",
                    description: Text(
                        ShiftHubLocalization.string("勤務表を選択すると、ここに保存されます。", locale: displayLocale)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(schedules) { schedule in
                        HStack(spacing: 8) {
                            Button {
                                onSelect(schedule)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 38, height: 38)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(schedule.fileName)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)

                                        Text(schedule.importedAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    if schedule.id == selectedScheduleID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel(ShiftHubLocalization.string("表示中", locale: displayLocale))
                                    }
                                }
                            }
                            .buttonStyle(SavedScheduleRowButtonStyle())

                            Button {
#if os(macOS)
                                openWindow(id: "pdf-preview", value: schedule)
#else
                                previewSchedule = schedule
#endif
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("保存したPDFを表示")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                onDelete(schedule)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
#if os(iOS)
        .sheet(item: $previewSchedule) { schedule in
            SavedSchedulePreviewView(
                schedule: schedule,
                onSelect: { selectedSchedule in
                    previewSchedule = nil
                    onSelect(selectedSchedule)
                }
            )
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 540, height: 440)
#endif
    }
}

struct PDFListView: View {
    let schedules: [StoredSchedule]
    let selectedScheduleID: UUID?
    let onDelete: (StoredSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var previewSchedule: StoredSchedule?
#endif

    private var displayLocale: Locale {
        Locale(identifier: appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShiftHubLocalization.string("履歴", locale: displayLocale))
                        .font(.title2.bold())

                    Text(ShiftHubLocalization.string("保存したPDFを表示または削除できます。", locale: displayLocale))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    Text("\(schedules.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(ShiftHubLocalization.string("完了", locale: displayLocale)) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            if schedules.isEmpty {
                ContentUnavailableView(
                    ShiftHubLocalization.string("保存したPDFがありません", locale: displayLocale),
                    systemImage: "folder",
                    description: Text(
                        ShiftHubLocalization.string("PDFを読み込むと、ここに保存されます。", locale: displayLocale)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(schedules) { schedule in
                        HStack(spacing: 8) {
                            Button {
#if os(macOS)
                                openWindow(id: "pdf-viewer", value: schedule)
#else
                                previewSchedule = schedule
#endif
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 38, height: 38)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(schedule.fileName)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)

                                        Text(schedule.importedAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    if schedule.id == selectedScheduleID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel(ShiftHubLocalization.string("表示中", locale: displayLocale))
                                    }
                                }
                            }
                            .buttonStyle(SavedScheduleRowButtonStyle())

                            Button(role: .destructive) {
                                onDelete(schedule)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(ShiftHubLocalization.string("削除", locale: displayLocale))
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
#if os(iOS)
        .sheet(item: $previewSchedule) { schedule in
            SavedSchedulePreviewView(
                schedule: schedule,
                onSelect: nil,
                showsScanAction: false
            )
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 540, height: 440)
#endif
    }
}

struct SavedSchedulePreviewView: View {
    let onSelect: ((StoredSchedule) -> Void)?
    let showsScanAction: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @StateObject private var primaryController = PDFPreviewController()
    @StateObject private var secondaryController = PDFPreviewController()
#else
    @StateObject private var controller = PDFPreviewController()
#endif
    @State private var displayedSchedule: StoredSchedule
    @State private var document: PDFDocument?
#if os(macOS)
    @State private var secondaryDocument: PDFDocument?
    @State private var showingSecondaryDocument = false
    @State private var hasVisibleDocument = false
    @State private var loadingDocumentSlot: MacPDFDocumentSlot?
#endif
    @State private var loadError = false
    @State private var availableSchedules: [StoredSchedule] = []
    @State private var isLoadingDocument = false
    @State private var loadingScheduleID: UUID?

    init(
        schedule: StoredSchedule,
        onSelect: ((StoredSchedule) -> Void)?,
        showsScanAction: Bool = true
    ) {
        self.onSelect = onSelect
        self.showsScanAction = showsScanAction
        _displayedSchedule = State(initialValue: schedule)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.accentColor)

                Text(displayedSchedule.fileName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button {
                    showPreviousSchedule()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("前のPDF")
                .accessibilityLabel("前のPDF")
                .disabled(isLoadingDocument || !canShowPreviousSchedule)

                Button {
                    showNextSchedule()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("次のPDF")
                .accessibilityLabel("次のPDF")
                .disabled(isLoadingDocument || !canShowNextSchedule)

                Button {
                    activePreviewController.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("縮小")
                .accessibilityLabel("縮小")

                Button {
                    activePreviewController.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("拡大")
                .accessibilityLabel("拡大")

                Button {
                    activePreviewController.fitToPage()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("ページに合わせる")
                .accessibilityLabel("ページに合わせる")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let document {
#if os(macOS)
                ZStack {
                    macPDFDocumentView
                        .opacity(hasVisibleDocument ? 1 : 0)

                    if !hasVisibleDocument {
                        ProgressView()
                    }
                }
#else
                PDFDocumentView(document: document, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
            } else if loadError {
                ContentUnavailableView(
                    "PDFを表示できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text("保存したPDFを開けませんでした。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#if os(macOS)
            Divider()
            previewActionBar
#endif
        }
#if os(iOS)
        .safeAreaInset(edge: .bottom) {
            previewActionBar
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(minWidth: 760, minHeight: 560)
#endif
        .onAppear {
            availableSchedules = StoredScheduleStore.loadSchedules()
            loadDisplayedSchedule()
        }
    }

    private func loadDisplayedSchedule() {
        loadSchedule(displayedSchedule)
    }

    private var activePreviewController: PDFPreviewController {
#if os(macOS)
        showingSecondaryDocument ? secondaryController : primaryController
#else
        controller
#endif
    }

#if os(macOS)
    private var macPDFDocumentView: some View {
        ZStack {
            if let document {
                PDFDocumentView(
                    document: document,
                    controller: primaryController,
                    onFirstRender: {
                        finishRenderingDocument(in: .primary)
                    }
                )
                .id(ObjectIdentifier(document))
                .opacity(showingSecondaryDocument ? 0 : 1)
            }

            if let secondaryDocument {
                PDFDocumentView(
                    document: secondaryDocument,
                    controller: secondaryController,
                    onFirstRender: {
                        finishRenderingDocument(in: .secondary)
                    }
                )
                .id(ObjectIdentifier(secondaryDocument))
                .opacity(showingSecondaryDocument ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishRenderingDocument(in slot: MacPDFDocumentSlot) {
        guard loadingDocumentSlot == slot else { return }

        showingSecondaryDocument = slot == .secondary
        hasVisibleDocument = true
        loadingDocumentSlot = nil
        loadingScheduleID = nil
        isLoadingDocument = false
    }
#endif

    private func loadSchedule(_ schedule: StoredSchedule) {
        guard !isLoadingDocument else { return }

        let scheduleID = schedule.id
        isLoadingDocument = true
        loadingScheduleID = scheduleID
        loadError = false

        Task { @MainActor in
            do {
                let url = try StoredScheduleStore.fileURL(for: schedule)
                guard FileManager.default.fileExists(atPath: url.path),
                      let loadedDocument = PDFDocument(url: url),
                      loadedDocument.pageCount > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                guard loadingScheduleID == scheduleID else { return }
#if os(macOS)
                displayedSchedule = schedule

                if document == nil {
                    document = loadedDocument
                    loadingDocumentSlot = .primary
                } else if showingSecondaryDocument {
                    document = loadedDocument
                    loadingDocumentSlot = .primary
                } else {
                    secondaryDocument = loadedDocument
                    loadingDocumentSlot = .secondary
                }
#else
                document = loadedDocument
                displayedSchedule = schedule
#endif
            } catch {
                guard loadingScheduleID == scheduleID else { return }
#if os(macOS)
                if !hasVisibleDocument {
                    loadError = true
                }
                loadingDocumentSlot = nil
                loadingScheduleID = nil
                isLoadingDocument = false
#else
                if document == nil {
                    loadError = true
                }
#endif
            }

#if os(iOS)
            loadingScheduleID = nil
            isLoadingDocument = false
#endif
        }
    }

    private var displayedScheduleIndex: Int? {
        availableSchedules.firstIndex { $0.id == displayedSchedule.id }
    }

    private var canShowPreviousSchedule: Bool {
        guard let index = displayedScheduleIndex else { return false }
        return index > 0
    }

    private var canShowNextSchedule: Bool {
        guard let index = displayedScheduleIndex else { return false }
        return index + 1 < availableSchedules.count
    }

    private func showPreviousSchedule() {
        guard let index = displayedScheduleIndex, index > 0 else { return }
        loadSchedule(availableSchedules[index - 1])
    }

    private func showNextSchedule() {
        guard let index = displayedScheduleIndex,
              index + 1 < availableSchedules.count else { return }
        loadSchedule(availableSchedules[index + 1])
    }

    private var previewActionBar: some View {
        HStack {
            Button("閉じる") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

#if os(macOS)
            if showsScanAction {
                Button(
                    ShiftHubLocalization.string("このPDFをスキャン", locale: Locale(identifier: appLanguage))
                ) {
                    NotificationCenter.default.post(
                        name: .shiftHubScanStoredSchedule,
                        object: displayedSchedule
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || isLoadingDocument)
            }
#else
            if showsScanAction, let onSelect {
                Button(
                    ShiftHubLocalization.string("このPDFをスキャン", locale: Locale(identifier: appLanguage))
                ) {
                    dismiss()
                    onSelect(displayedSchedule)
                }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || isLoadingDocument)
            }
#endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

final class PDFPreviewController: ObservableObject {
    weak var pdfView: PDFView?

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.scaleFactor = min(pdfView.scaleFactor * 1.25, pdfView.maxScaleFactor)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.scaleFactor = max(pdfView.scaleFactor / 1.25, pdfView.minScaleFactor)
    }

    func fitToPage() {
        pdfView?.autoScales = true
    }
}

#if os(macOS)
enum MacPDFDocumentSlot {
    case primary
    case secondary
}
#endif

struct PDFDocumentView: View {
    let document: PDFDocument
    let controller: PDFPreviewController
    let onFirstRender: (() -> Void)?

    init(
        document: PDFDocument,
        controller: PDFPreviewController,
        onFirstRender: (() -> Void)? = nil
    ) {
        self.document = document
        self.controller = controller
        self.onFirstRender = onFirstRender
    }

    var body: some View {
#if os(iOS)
        PDFKitRepresentable(document: document, controller: controller)
#else
        PDFKitRepresentable(
            document: document,
            controller: controller,
            onFirstRender: onFirstRender
        )
#endif
    }
}

#if os(iOS)
final class IOSPDFPreviewView: PDFView {
    private var shouldFitPageToWidth = true
    private var pendingDocument: PDFDocument?

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInitialPageWidthFitIfNeeded()
        applyPageCornerRadius()
    }

    func prepareForInitialWidthFit() {
        shouldFitPageToWidth = true
        setNeedsLayout()
    }

    func setDocumentWhenReady(_ document: PDFDocument) {
        guard self.document !== document else { return }

        pendingDocument = document
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingDocument === document else { return }

            pendingDocument = nil
            prepareForInitialWidthFit()
            self.document = document
        }
    }

    private func applyInitialPageWidthFitIfNeeded() {
        guard shouldFitPageToWidth,
              bounds.width > 0,
              let page = document?.page(at: 0) else { return }

        let pageWidth = page.bounds(for: displayBox).width
        guard pageWidth > 0 else { return }

        // Mark the fit as complete before changing PDFView layout state to avoid reentrant layout.
        shouldFitPageToWidth = false
        autoScales = false
        scaleFactor = min(max(bounds.width / pageWidth, minScaleFactor), maxScaleFactor)
    }

    private func applyPageCornerRadius() {
        documentView?.layer.cornerRadius = 15
        documentView?.layer.masksToBounds = true
    }
}

struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let controller: PDFPreviewController

    func makeUIView(context: Context) -> IOSPDFPreviewView {
        let pdfView = IOSPDFPreviewView()
        configure(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: IOSPDFPreviewView, context: Context) {
        pdfView.setDocumentWhenReady(document)
        controller.pdfView = pdfView
    }

    private func configure(_ pdfView: IOSPDFPreviewView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = .zero
        pdfView.minScaleFactor = 0.75
        pdfView.maxScaleFactor = 5.0
        pdfView.autoScales = false
        pdfView.prepareForInitialWidthFit()
        pdfView.document = document
        controller.pdfView = pdfView
    }
}
#else
final class MacPDFPreviewView: PDFView {
    var onFirstRender: (() -> Void)?
    private var didReportFirstRender = false

    override func layout() {
        super.layout()
        applyPageCornerRadius()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !didReportFirstRender, document?.pageCount ?? 0 > 0 else { return }
        didReportFirstRender = true

        DispatchQueue.main.async { [weak self] in
            self?.onFirstRender?()
        }
    }

    private func applyPageCornerRadius() {
        documentView?.wantsLayer = true
        documentView?.layer?.cornerRadius = 15
        documentView?.layer?.masksToBounds = true
    }
}

struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let controller: PDFPreviewController
    let onFirstRender: (() -> Void)?

    func makeNSView(context: Context) -> MacPDFPreviewView {
        let pdfView = MacPDFPreviewView()
        pdfView.onFirstRender = onFirstRender
        configure(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: MacPDFPreviewView, context: Context) {
        pdfView.onFirstRender = onFirstRender
        controller.pdfView = pdfView
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.minScaleFactor = 0.75
        pdfView.maxScaleFactor = 5.0
        pdfView.autoScales = true
        controller.pdfView = pdfView
    }
}
#endif
