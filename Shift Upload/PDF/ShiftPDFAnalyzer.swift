import Foundation
import ImageIO
import PDFKit
import Vision

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

final class ShiftOCRAnalyzer {
    private let gridDetector = ShiftPDFGridDetector()
    private var latestTableGrids: [PDFTableGrid] = []

    func yearMonth(from items: [RecognizedTextItem]) -> YearMonth? {
        for item in items {
            if let yearMonth = yearMonth(from: item.rawPageText ?? item.text) {
                return yearMonth
            }
        }

        return nil
    }

    func recognizeText(in url: URL) async throws -> [RecognizedTextItem] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
            throw ShiftOCRAnalyzerError.unsupportedFile
        }

        guard let document = PDFDocument(url: url) else {
            throw ShiftOCRAnalyzerError.unreadableFile
        }

        let textLayerItems = textLayerItems(from: document)
        guard !textLayerItems.isEmpty else {
            throw ShiftOCRAnalyzerError.missingTextLayer
        }
        guard Self.supportsHorizontalTextLayout(document) else {
            throw ShiftOCRAnalyzerError.unsupportedLayout
        }

        latestTableGrids = gridDetector.detect(
            in: document,
            textItems: textLayerItems,
            dayCount: yearMonth(from: textLayerItems)?.numberOfDays ?? 31
        )

        return sortedItems(textLayerItems)
    }

    static func supportsHorizontalTextLayout(_ document: PDFDocument) -> Bool {
        guard document.pageCount > 0 else { return false }

        return (0..<document.pageCount).allSatisfy { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                return false
            }

            let dateTokens = dateSequence(in: textLayerTokens(from: page))
            guard dateTokens.count >= 20 else {
                return false
            }

            let xValues = dateTokens.map { $0.bounds.midX }
            let yValues = dateTokens.map { $0.bounds.midY }
            guard let minX = xValues.min(), let maxX = xValues.max(),
                  let minY = yValues.min(), let maxY = yValues.max() else {
                return false
            }

            let xSpan = maxX - minX
            let ySpan = maxY - minY
            let increasingXCount = zip(dateTokens.dropFirst(), dateTokens).filter { current, previous in
                current.bounds.midX > previous.bounds.midX
            }.count

            return xSpan > ySpan * 2 && increasingXCount >= dateTokens.count - 2
        }
    }

    private struct TextLayerToken {
        let text: String
        let bounds: CGRect
        let order: Int

        init(text: String, bounds: CGRect, order: Int = 0) {
            self.text = text
            self.bounds = bounds
            self.order = order
        }
    }

    private static func textLayerTokens(from page: PDFPage, in document: PDFDocument? = nil) -> [TextLayerToken] {
        guard let pageText = page.string else {
            return []
        }

        let text = pageText as NSString
        var tokens: [TextLayerToken] = []
        var tokenText = ""
        var tokenBounds = CGRect.null
        var tokenStartIndex: Int?

        func appendToken() {
            let trimmedText = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty, !tokenBounds.isNull else {
                tokenText = ""
                tokenBounds = .null
                tokenStartIndex = nil
                return
            }

            let bounds: CGRect
            if let document,
               let tokenStartIndex,
               let selection = document.selection(
                   from: page,
                   atCharacterIndex: tokenStartIndex,
                   to: page,
                   atCharacterIndex: tokenStartIndex + tokenText.utf16.count - 1
               ) {
                let selectionBounds = selection.bounds(for: page)
                // Some PDF text layers return an empty selection bounds for
                // glyphs over a colored cell background. Keep the original
                // character bounds so those cells are not discarded.
                bounds = selectionBounds.isNull || selectionBounds.width <= 0 || selectionBounds.height <= 0
                    ? tokenBounds
                    : selectionBounds
            } else {
                bounds = tokenBounds
            }

            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
                tokenText = ""
                tokenBounds = .null
                tokenStartIndex = nil
                return
            }

            tokens.append(TextLayerToken(
                text: trimmedText,
                bounds: bounds,
                order: tokenStartIndex ?? tokens.count
            ))
            tokenText = ""
            tokenBounds = .null
            tokenStartIndex = nil
        }

        for index in 0..<min(page.numberOfCharacters, text.length) {
            let character = text.substring(with: NSRange(location: index, length: 1))
            if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                appendToken()
                continue
            }

            let bounds = page.characterBounds(at: index)
            if tokenStartIndex == nil {
                tokenStartIndex = index
            }
            tokenText.append(character)
            tokenBounds = tokenBounds.isNull ? bounds : tokenBounds.union(bounds)
        }
        appendToken()

        return tokens
    }

    private static func dateSequence(in tokens: [TextLayerToken]) -> [TextLayerToken] {
        var bestSequence: [TextLayerToken] = []

        for startIndex in tokens.indices {
            guard normalizedText(tokens[startIndex].text) == "1" else {
                continue
            }

            var expectedDay = 1
            var sequence: [TextLayerToken] = []
            for token in tokens[startIndex...] {
                guard normalizedText(token.text) == String(expectedDay) else {
                    continue
                }

                sequence.append(token)
                expectedDay += 1
                if expectedDay > 31 {
                    break
                }
            }

            if sequence.count > bestSequence.count {
                bestSequence = sequence
            }
        }

        return bestSequence
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sortedItems(_ items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        items.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    func extractRowItems(matching name: String, from items: [RecognizedTextItem], yearMonth: YearMonth?) -> [ExtractedShiftCell] {
        let normalizedName = normalize(name)
        guard !normalizedName.isEmpty,
              !normalizedName.contains(where: { $0.isNumber }) else {
            return []
        }

        if let cells = gridCells(matching: normalizedName, from: items, yearMonth: yearMonth) {
            return cells
        }

        if let cells = textLayerCells(matching: normalizedName, from: items, yearMonth: yearMonth) {
            return cells
        }

        return directTextCells(matching: normalizedName, from: items, yearMonth: yearMonth) ?? []
    }

    private func gridCells(
        matching normalizedName: String,
        from items: [RecognizedTextItem],
        yearMonth: YearMonth?
    ) -> [ExtractedShiftCell]? {
        let dayCount = yearMonth?.numberOfDays ?? 31
        let tokenItems = items.filter { $0.rawPageText == nil }

        for grid in latestTableGrids {
            let pageTokens = tokenItems.filter { $0.pageIndex == grid.pageIndex }
            guard let row = grid.rows.first(where: { row in
                let nameTokens = pageTokens
                    .filter { row.nameCell.bounds.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
                    .sorted { lhs, rhs in
                        if let lhsOrder = lhs.textLayerOrder,
                           let rhsOrder = rhs.textLayerOrder,
                           lhsOrder != rhsOrder {
                            return lhsOrder < rhsOrder
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                let rowName = normalize(nameTokens.map(\.text).joined())
                return rowName.hasPrefix(normalizedName) || rowName.contains(normalizedName)
            }) else {
                continue
            }

            let cells = row.dayCells.prefix(dayCount).map { cell in
                let cellTokens = pageTokens
                    .filter { cell.bounds.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
                    .sorted { lhs, rhs in
                        if let lhsOrder = lhs.textLayerOrder,
                           let rhsOrder = rhs.textLayerOrder,
                           lhsOrder != rhsOrder {
                            return lhsOrder < rhsOrder
                        }
                        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                            return lhs.boundingBox.midY > rhs.boundingBox.midY
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }

                return ExtractedShiftCell(
                    dateText: String(cell.day ?? 0),
                    valueText: normalizedShiftText(cellTokens.map(\.text).joined()),
                    pageIndex: grid.pageIndex,
                    boundingBox: cellTokens.map(\.boundingBox).reduce(.null) { $0.union($1) }
                )
            }

            guard cells.count == dayCount else { continue }
            return cells
        }

        return nil
    }

    private func textLayerCells(
        matching normalizedName: String,
        from items: [RecognizedTextItem],
        yearMonth: YearMonth?
    ) -> [ExtractedShiftCell]? {
        let dayCount = yearMonth?.numberOfDays ?? 31
        let tokenItems = items.filter { $0.rawPageText == nil }

        for pageIndex in Set(tokenItems.map(\.pageIndex)).sorted() {
            let pageTokens = tokenItems
                .filter { $0.pageIndex == pageIndex }
                .sorted { lhs, rhs in
                    if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                        return lhs.boundingBox.midY > rhs.boundingBox.midY
                    }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }

            let dateTokens = Self.dateSequence(
                in: pageTokens.map { TextLayerToken(text: $0.text, bounds: $0.boundingBox) }
            )
            guard dateTokens.count >= dayCount else { continue }

            let dateColumns = dateTokens.prefix(dayCount).enumerated().map { index, token in
                DateColumn(day: index + 1, centerX: token.bounds.midX, pageIndex: pageIndex)
            }
            guard let target = targetTextLayerRow(
                matching: normalizedName,
                in: pageTokens
            ) else {
                continue
            }

            let rowTokens = textLayerTokens(
                in: target.rowRange,
                from: pageTokens
            )
            let cells = dateColumns.map { column in
                let range = dateCellRange(for: column, in: dateColumns)
                let cellTokens = rowTokens
                    .filter { range.contains($0.boundingBox.midX) }
                    .sorted { lhs, rhs in
                        if let lhsOrder = lhs.textLayerOrder,
                           let rhsOrder = rhs.textLayerOrder,
                           lhsOrder != rhsOrder {
                            return lhsOrder < rhsOrder
                        }
                        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                            return lhs.boundingBox.midY > rhs.boundingBox.midY
                        }
                        return lhs.boundingBox.minX < rhs.boundingBox.minX
                    }
                let valueText = normalizedShiftText(cellTokens.map(\.text).joined())

                return ExtractedShiftCell(
                    dateText: String(column.day),
                    valueText: valueText,
                    pageIndex: pageIndex,
                    boundingBox: cellTokens.map(\.boundingBox).reduce(.null) { $0.union($1) }
                )
            }

            return cells
        }

        return nil
    }

    private struct TextLayerRow {
        let rowRange: ClosedRange<CGFloat>
    }

    private func targetTextLayerRow(
        matching normalizedName: String,
        in pageTokens: [RecognizedTextItem]
    ) -> TextLayerRow? {
        let rows = rowGroups(from: pageTokens).map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }
        let target = rows.compactMap { row -> (row: [RecognizedTextItem], nameBounds: CGRect)? in
            guard let nameBounds = nameBounds(in: row, matching: normalizedName) else {
                return nil
            }

            return (row: row, nameBounds: nameBounds)
        }.first
        guard let target else { return nil }

        let nameCenterY = target.nameBounds.midY
        let anchorTolerance = max(target.nameBounds.width * 0.75, 0.02)
        let allRowCenters = rows.map { row in
            row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
        }
        let neighboringNameCenters = rows.compactMap { row -> CGFloat? in
            guard row != target.row else {
                return nil
            }

            guard row.contains(where: {
                abs($0.boundingBox.minX - target.nameBounds.minX) <= anchorTolerance
            }) else {
                return nil
            }

            let centerY = row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
            return abs(centerY - nameCenterY) > 0.01 ? centerY : nil
        }

        let upperAnchor = (neighboringNameCenters
            .filter { $0 > nameCenterY }
            .min() ?? allRowCenters.filter { $0 > nameCenterY }.min())
        let lowerAnchor = (neighboringNameCenters
            .filter { $0 < nameCenterY }
            .max() ?? allRowCenters.filter { $0 < nameCenterY }.max())
        // A wrapped value stays within the midpoint between neighboring rows.
        // Expanding this range can accidentally merge adjacent employees.
        let upperBound = upperAnchor.map { (nameCenterY + $0) / 2 } ?? .greatestFiniteMagnitude
        let lowerBound = lowerAnchor.map { (nameCenterY + $0) / 2 } ?? -.greatestFiniteMagnitude

        return TextLayerRow(
            rowRange: lowerBound...upperBound
        )
    }

    private func textLayerTokens(
        in rowRange: ClosedRange<CGFloat>,
        from pageTokens: [RecognizedTextItem]
    ) -> [RecognizedTextItem] {
        return pageTokens.filter {
            rowRange.contains($0.boundingBox.midY)
        }
    }

    private func dateCellRange(
        for column: DateColumn,
        in columns: [DateColumn]
    ) -> ClosedRange<CGFloat> {
        let sortedColumns = columns.sorted { $0.centerX < $1.centerX }
        guard let index = sortedColumns.firstIndex(of: column) else {
            return column.centerX...column.centerX
        }

        let leftStep: CGFloat
        if index > sortedColumns.startIndex {
            leftStep = column.centerX - sortedColumns[index - 1].centerX
        } else if index + 1 < sortedColumns.endIndex {
            leftStep = sortedColumns[index + 1].centerX - column.centerX
        } else {
            leftStep = 0.05
        }

        let rightStep: CGFloat
        if index + 1 < sortedColumns.endIndex {
            rightStep = sortedColumns[index + 1].centerX - column.centerX
        } else if index > sortedColumns.startIndex {
            rightStep = column.centerX - sortedColumns[index - 1].centerX
        } else {
            rightStep = 0.05
        }

        return (column.centerX - leftStep / 2)...(column.centerX + rightStep / 2)
    }

    private func fallbackCells(from rowItems: [RecognizedTextItem], excludingNameBounds nameBounds: CGRect?) -> [ExtractedShiftCell] {
        shiftValueItems(in: rowItems, excludingNameBounds: nameBounds)
            .map { item in
                ExtractedShiftCell(
                    dateText: "",
                    valueText: normalizedShiftText(item.text),
                    pageIndex: item.pageIndex,
                    boundingBox: item.boundingBox
                )
            }
    }

    private func directTextCells(matching normalizedName: String, from items: [RecognizedTextItem], yearMonth: YearMonth?) -> [ExtractedShiftCell]? {
        let dayCount = yearMonth?.numberOfDays ?? 31

        for item in items where item.rawPageText != nil {
            guard let rawPageText = item.rawPageText else { continue }
            let tokens = rawPageText.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let valueStartIndex = indexAfterName(in: tokens, matching: normalizedName) else {
                continue
            }

            let values = shiftValues(from: Array(tokens[valueStartIndex...]), dayCount: dayCount)
            guard !values.isEmpty else { continue }
            let adjustedValues = adjustedWrappedRestSuffixes(in: values)

            return (1...dayCount).map { day in
                ExtractedShiftCell(
                    dateText: String(day),
                    valueText: day <= adjustedValues.count ? normalizedShiftText(adjustedValues[day - 1]) : "",
                    pageIndex: item.pageIndex,
                    boundingBox: CGRect(x: CGFloat(day) / CGFloat(max(dayCount, 1)), y: 0, width: 0, height: 0)
                )
            }
        }

        return nil
    }

    private func indexAfterName(in tokens: [String], matching normalizedName: String) -> Int? {
        // スペースで分かれた名前を連結し、入力が名前トークンの途中で
        // 終わっていても、そのトークン全体を名前として消費する。
        for startIndex in tokens.indices {
            var combinedText = ""

            for endIndex in startIndex..<tokens.count {
                let tokenText = normalize(tokens[endIndex])
                let candidateText = combinedText + tokenText

                if candidateText == normalizedName || candidateText.hasPrefix(normalizedName) {
                    return tokens.index(after: endIndex)
                }

                if !normalizedName.hasPrefix(candidateText) {
                    break
                }

                combinedText = candidateText
            }
        }

        // PDFのテキスト層では、スペースのないフルネームが1トークンに
        // まとまることがある。名字だけ入力された場合も、そのトークン
        // 全体を名前として消費して、直後から勤務値を読み取る。
        for (index, token) in tokens.enumerated() {
            let normalizedToken = normalize(token)
            if normalizedToken != normalizedName,
               normalizedToken.hasPrefix(normalizedName) {
                return tokens.index(after: index)
            }
        }

        return nil
    }

    private func shiftValues(from tokens: [String], dayCount: Int) -> [String] {
        var values: [String] = []

        for rawToken in tokens {
            for token in normalizedShiftTokens(in: rawToken) {
                let normalizedToken = normalizedShiftText(token)
                guard !normalizedToken.isEmpty else { continue }

                if values.count >= dayCount || isSummaryToken(normalizedToken) {
                    return values
                }

                if values.last?.hasSuffix("/") == true {
                    values[values.count - 1] += normalizedToken
                    continue
                }

                if isContinuationToken(normalizedToken), !values.isEmpty {
                    values[values.count - 1] += normalizedToken
                    continue
                }

                guard isShiftValueStart(normalizedToken) else {
                    continue
                }

                values.append(normalizedToken)
            }
        }

        return values
    }

    private func normalizedShiftTokens(in token: String) -> [String] {
        // 「半年」「半年/5」のような複合勤務値は1日分として扱う。
        [normalizedShiftText(token)]
    }

    private func adjustedWrappedRestSuffixes(in values: [String]) -> [String] {
        var adjustedValues = values

        for index in adjustedValues.indices.dropLast() {
            guard adjustedValues[index].hasSuffix("/休") else {
                continue
            }

            let baseValue = String(adjustedValues[index].dropLast(2))
            if !baseValue.isEmpty, adjustedValues[index + 1] == baseValue {
                adjustedValues[index] = baseValue
                adjustedValues[index + 1] = "\(baseValue)/休"
            }
        }

        return adjustedValues
    }

    private func isSummaryToken(_ token: String) -> Bool {
        token.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
    }

    private func isContinuationToken(_ token: String) -> Bool {
        token.hasPrefix("/") || !isShiftValueStart(token)
    }

    private func isShiftValueStart(_ token: String) -> Bool {
        token.range(of: #"[休半年△□①②③④⑤⑥⑦⑧⑨]|\d|\*"#, options: .regularExpression) != nil
    }

    private func yearMonth(from text: String) -> YearMonth? {
        let patterns = [
            #"(\d{4})\s*/\s*(\d{1,2})"#,
            #"(\d{4})\s*年\s*(\d{1,2})\s*月"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let yearRange = Range(match.range(at: 1), in: text),
                  let monthRange = Range(match.range(at: 2), in: text),
                  let year = Int(text[yearRange]),
                  let month = Int(text[monthRange]),
                  (1...12).contains(month) else {
                continue
            }

            return YearMonth(year: year, month: month)
        }

        return nil
    }

    private func rowGroups(from items: [RecognizedTextItem]) -> [[RecognizedTextItem]] {
        let sortedItems = items.sorted {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }

        return sortedItems.reduce(into: [[RecognizedTextItem]]()) { rows, item in
            // Tokens on one visual row can have slightly different baselines,
            // but adjacent rows are separated by a much larger gap.
            let tolerance = min(max(item.boundingBox.height * 0.4, 4.0), 5.0)
            if let index = rows.firstIndex(where: { row in
                guard let firstItem = row.first else { return false }
                return firstItem.pageIndex == item.pageIndex
                    && abs(firstItem.boundingBox.midY - item.boundingBox.midY) <= tolerance
            }) {
                rows[index].append(item)
            } else {
                rows.append([item])
            }
        }
    }

    private func nameBounds(in rowItems: [RecognizedTextItem], matching normalizedName: String) -> CGRect? {
        var combinedText = ""
        var nameItems: [RecognizedTextItem] = []

        for item in rowItems {
            let itemText = normalize(item.text)
            guard !itemText.isEmpty else { continue }

            let candidateText = combinedText + itemText
            if candidateText == normalizedName {
                nameItems.append(item)
                return unionBounds(of: nameItems)
            } else if normalizedName.hasPrefix(candidateText) {
                combinedText = candidateText
                nameItems.append(item)
            } else if candidateText.hasPrefix(normalizedName) {
                // The query can end in the middle of a PDF name token, for
                // example "成田智" while the token is "智明".
                nameItems.append(item)
                return unionBounds(of: nameItems)
            } else if itemText.hasPrefix(normalizedName) {
                combinedText = itemText
                nameItems = [item]
            } else {
                combinedText = ""
                nameItems = []
            }
        }

        return rowItems.first { item in
            normalize(item.text).contains(normalizedName)
        }?.boundingBox
    }

    private func logicalRowItems(
        containing targetRow: [RecognizedTextItem],
        nameBounds: CGRect?,
        from items: [RecognizedTextItem]
    ) -> [RecognizedTextItem] {
        guard let targetItem = targetRow.first,
              let targetNameBounds = nameBounds else {
            return targetRow.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }

        let rows = rowGroups(from: items).filter { row in
            row.first?.pageIndex == targetItem.pageIndex
        }
        let targetCenterY = targetNameBounds.midY
        let targetNameX = targetNameBounds.minX
        let anchorTolerance = max(targetNameBounds.width * 0.75, 0.012)
        let nameAnchors = rows.filter { row in
            guard let leftmostItem = row.min(by: { $0.boundingBox.minX < $1.boundingBox.minX }) else {
                return false
            }

            return abs(leftmostItem.boundingBox.minX - targetNameX) <= anchorTolerance
        }

        let nearestAbove = nameAnchors
            .map { $0.map(\.boundingBox.midY).reduce(0, +) / CGFloat($0.count) }
            .filter { $0 > targetCenterY }
            .min()
        let nearestBelow = nameAnchors
            .map { $0.map(\.boundingBox.midY).reduce(0, +) / CGFloat($0.count) }
            .filter { $0 < targetCenterY }
            .max()

        let upperBound = nearestAbove.map { (targetCenterY + $0) / 2 } ?? .greatestFiniteMagnitude
        let lowerBound = nearestBelow.map { (targetCenterY + $0) / 2 } ?? -.greatestFiniteMagnitude

        let mergedItems = rows
            .filter { row in
                let rowCenterY = row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
                return rowCenterY <= upperBound && rowCenterY >= lowerBound
            }
            .flatMap { $0 }

        return (mergedItems.isEmpty ? targetRow : mergedItems)
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    }

    private func refinedRowItems(around nameBounds: CGRect?, from items: [RecognizedTextItem], fallback: [RecognizedTextItem]) -> [RecognizedTextItem] {
        guard let nameBounds, let pageIndex = fallback.first?.pageIndex else {
            return fallback
        }

        let rowCenterY = nameBounds.midY
        let tolerance = max(nameBounds.height * 3.0, 0.024)
        let rowItems = items.filter { item in
            item.pageIndex == pageIndex
                && abs(item.boundingBox.midY - rowCenterY) <= tolerance
        }

        return rowItems.isEmpty ? fallback : rowItems.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    }

    private func shiftValueItems(in rowItems: [RecognizedTextItem], excludingNameBounds nameBounds: CGRect?) -> [RecognizedTextItem] {
        rowItems.filter { item in
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return false }

            if let nameBounds {
                return item.boundingBox.minX > nameBounds.maxX
            }

            return true
        }
    }

    private func dateHeaderItems(above rowItems: [RecognizedTextItem], from items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        guard let firstRowItem = rowItems.first else { return [] }
        let dateCandidates = items.filter { item in
            item.pageIndex == firstRowItem.pageIndex
                && item.boundingBox.midY > firstRowItem.boundingBox.midY
                && dateNumber(from: item.text) != nil
        }

        guard !dateCandidates.isEmpty else { return [] }

        let rows = rowGroups(from: dateCandidates)
        return rows
            .max { lhs, rhs in lhs.count < rhs.count }?
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX } ?? []
    }

    private func inferredDateColumns(above rowItems: [RecognizedTextItem], from items: [RecognizedTextItem], dayCount: Int) -> [DateColumn] {
        let headerItems = dateHeaderItems(above: rowItems, from: items)
        let knownColumns = headerItems.compactMap { item -> DateColumn? in
            guard let day = dateNumber(from: item.text), (1...dayCount).contains(day) else {
                return nil
            }

            return DateColumn(day: day, centerX: item.boundingBox.midX, pageIndex: item.pageIndex)
        }

        guard !knownColumns.isEmpty else { return [] }

        if let first = knownColumns.first(where: { $0.day == 1 }),
           let last = knownColumns.first(where: { $0.day == dayCount }),
           first.centerX < last.centerX {
            let step = (last.centerX - first.centerX) / CGFloat(dayCount - 1)
            return (1...dayCount).map { day in
                DateColumn(day: day, centerX: first.centerX + CGFloat(day - 1) * step, pageIndex: first.pageIndex)
            }
        }

        let step = estimatedDateColumnStep(from: knownColumns)
        guard step > 0 else {
            return knownColumns.sorted { $0.day < $1.day }
        }

        let anchor = knownColumns.sorted { $0.day < $1.day }[knownColumns.count / 2]
        return (1...dayCount).map { day in
            DateColumn(day: day, centerX: anchor.centerX + CGFloat(day - anchor.day) * step, pageIndex: anchor.pageIndex)
        }
    }

    private func estimatedDateColumnStep(from columns: [DateColumn]) -> CGFloat {
        let sortedColumns = columns.sorted { $0.day < $1.day }
        let steps = zip(sortedColumns.dropFirst(), sortedColumns).compactMap { current, previous -> CGFloat? in
            let dayDistance = current.day - previous.day
            guard dayDistance > 0 else { return nil }

            return (current.centerX - previous.centerX) / CGFloat(dayDistance)
        }
        .filter { $0 > 0 }
        .sorted()

        guard !steps.isEmpty else { return 0 }
        return steps[steps.count / 2]
    }

    private func dateColumnRange(from columns: [DateColumn]) -> ClosedRange<CGFloat> {
        let centers = columns.map(\.centerX).sorted()
        guard centers.count >= 2 else {
            let center = centers.first ?? 0
            return (center - 0.03)...(center + 0.03)
        }

        let averageStep = zip(centers.dropFirst(), centers).map(-).reduce(0, +) / CGFloat(centers.count - 1)
        let padding = max(averageStep * 0.55, 0.02)
        return (centers[0] - padding)...(centers[centers.count - 1] + padding)
    }

    private func nearestDateColumn(for item: RecognizedTextItem, in columns: [DateColumn]) -> DateColumn? {
        columns.min { lhs, rhs in
            abs(lhs.centerX - item.boundingBox.midX) < abs(rhs.centerX - item.boundingBox.midX)
        }
    }

    private func pageImages(from url: URL) throws -> [(index: Int, image: CGImage)] {
        if url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            guard let document = PDFDocument(url: url) else {
                throw ShiftOCRAnalyzerError.unreadableFile
            }

            return try (0..<document.pageCount).map { pageIndex in
                guard let page = document.page(at: pageIndex) else {
                    throw ShiftOCRAnalyzerError.unreadableFile
                }

                let pageBounds = page.bounds(for: .mediaBox)
                let targetWidth: CGFloat = 2400
                let scale = max(targetWidth / max(pageBounds.width, 1), 1)
                let imageSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
                let image = page.thumbnail(of: imageSize, for: .mediaBox)

                guard let cgImage = image.cgImageForOCR else {
                    throw ShiftOCRAnalyzerError.unreadableFile
                }

                return (pageIndex, cgImage)
            }
        }

        guard let cgImage = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              let normalizedImage = normalizedImageForOCR(cgImage) else {
            throw ShiftOCRAnalyzerError.unreadableFile
        }

        return [(0, normalizedImage)]
    }

    private func textLayerItems(from document: PDFDocument) -> [RecognizedTextItem] {
        (0..<document.pageCount).flatMap { pageIndex -> [RecognizedTextItem] in
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string,
                  !pageText.isEmpty else {
                return []
            }

            let pageItem = RecognizedTextItem(
                text: pageText,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                pageIndex: pageIndex,
                rawPageText: pageText,
                textLayerOrder: nil
            )
            let tokenItems = Self.textLayerTokens(from: page, in: document).map { token in
                RecognizedTextItem(
                    text: token.text,
                    boundingBox: token.bounds,
                    pageIndex: pageIndex,
                    rawPageText: nil,
                    textLayerOrder: token.order
                )
            }

            return [pageItem] + tokenItems
        }
    }

    private func recognizeText(in image: CGImage, pageIndex: Int) throws -> [RecognizedTextItem] {
        let regions = recognitionRegions(for: image)
        let items = try regions.flatMap { region in
            try recognizeText(in: image, pageIndex: pageIndex, regionOfInterest: region)
        }

        return deduplicatedItems(items)
    }

    private func recognizeText(
        in image: CGImage,
        pageIndex: Int,
        regionOfInterest: CGRect
    ) throws -> [RecognizedTextItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.002
        request.regionOfInterest = regionOfInterest

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else {
                return nil
            }

            return RecognizedTextItem(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                boundingBox: observation.boundingBox,
                pageIndex: pageIndex,
                rawPageText: nil,
                textLayerOrder: nil
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private func recognitionRegions(for image: CGImage) -> [CGRect] {
        // 表の高さは月ごとに変わるため、画像全体を相対的な帯に分けてOCRする。
        let bandCount = max(6, min(10, Int(ceil(Double(image.height) / Double(max(image.width, 1)) * 12))))
        let bandHeight = 1 / CGFloat(bandCount)
        let overlap = bandHeight * 0.2

        return (0..<bandCount).map { index in
            let minY = max(0, CGFloat(index) * bandHeight - overlap)
            let maxY = min(1, CGFloat(index + 1) * bandHeight + overlap)
            return CGRect(x: 0, y: minY, width: 1, height: maxY - minY)
        }
    }

    private func deduplicatedItems(_ items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        var result: [RecognizedTextItem] = []

        for item in items {
            guard let duplicateIndex = result.firstIndex(where: { existing in
                existing.pageIndex == item.pageIndex
                    && existing.boundingBox.intersection(item.boundingBox).isNull == false
                    && rectArea(existing.boundingBox.intersection(item.boundingBox))
                        >= min(rectArea(existing.boundingBox), rectArea(item.boundingBox)) * 0.45
            }) else {
                result.append(item)
                continue
            }

            if item.text.count > result[duplicateIndex].text.count {
                result[duplicateIndex] = item
            }
        }

        return result
    }

    private func rectArea(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    private func normalizedImageForOCR(_ image: CGImage) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // JPG/PNGの色空間やアルファ有無によるVision OCRの結果差を抑える。
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: imageSize))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        return context.makeImage()
    }

    private func nearestDateHeaderText(for item: RecognizedTextItem, in headers: [RecognizedTextItem]) -> String {
        headers
            .min { lhs, rhs in
                abs(lhs.boundingBox.midX - item.boundingBox.midX) < abs(rhs.boundingBox.midX - item.boundingBox.midX)
            }?
            .text ?? ""
    }

    private func dateNumber(from text: String) -> Int? {
        let normalized = normalize(text)
        guard let value = Int(normalized), (1...31).contains(value) else {
            return nil
        }

        return value
    }

    private func normalizedShiftText(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "体", with: "休")
            .replacingOccurrences(of: "口", with: "□")
            .replacingOccurrences(of: "ロ", with: "□")
            .replacingOccurrences(of: "A", with: "△")
            .replacingOccurrences(of: "▲", with: "△")

        if normalized == "祝" {
            normalized = ""
        }

        return normalized
    }

    private func unionBounds(of items: [RecognizedTextItem]) -> CGRect? {
        items.map(\.boundingBox).reduce(nil) { result, rect in
            result?.union(rect) ?? rect
        }
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ShiftOCRAnalyzerError: LocalizedError {
    case unsupportedFile
    case missingTextLayer
    case unsupportedLayout
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "PDFのみ対応しています"
        case .missingTextLayer:
            return "文字データを持つPDFではありません"
        case .unsupportedLayout:
            return "横型のPDFのみ対応しています"
        case .unreadableFile:
            return "PDFファイルを開けませんでした。"
        }
    }
}

#if os(macOS)
extension NSImage {
    var cgImageForOCR: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
#elseif os(iOS)
extension UIImage {
    var cgImageForOCR: CGImage? {
        cgImage
    }
}
#endif
