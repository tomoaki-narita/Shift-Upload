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
    private var latestRasterTables: [RasterTableGrid] = []

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

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "pdf" else {
            throw ShiftOCRAnalyzerError.unsupportedFile
        }

        latestRasterTables = []

        guard let document = PDFDocument(url: url) else {
            throw ShiftOCRAnalyzerError.unreadableFile
        }

        let textLayerItems = textLayerItems(from: document)
        guard !textLayerItems.isEmpty else {
            throw ShiftOCRAnalyzerError.missingTextLayer
        }
        guard Self.supportsSupportedTextLayout(document) else {
            throw ShiftOCRAnalyzerError.unsupportedLayout
        }

        latestTableGrids = gridDetector.detect(
            in: document,
            textItems: textLayerItems,
            dayCount: yearMonth(from: textLayerItems)?.numberOfDays ?? 31
        )

        return sortedItems(textLayerItems)
    }

    static func supportsSupportedTextLayout(_ document: PDFDocument) -> Bool {
        guard document.pageCount > 0 else { return false }

        return (0..<document.pageCount).allSatisfy { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                return false
            }

            let tokens = textLayerTokens(from: page)
            let horizontalDates = dateSequence(in: tokens)
            if horizontalDates.count >= 20 {
                let xSpan = horizontalDates.map { $0.bounds.midX }.max()! - horizontalDates.map { $0.bounds.midX }.min()!
                let ySpan = horizontalDates.map { $0.bounds.midY }.max()! - horizontalDates.map { $0.bounds.midY }.min()!
                if xSpan > ySpan * 2 {
                    return true
                }
            }

            let verticalDates = verticalDateSequence(in: tokens)
            if verticalDates.count >= 20 {
                let xSpan = verticalDates.map { $0.bounds.midX }.max()! - verticalDates.map { $0.bounds.midX }.min()!
                let ySpan = verticalDates.map { $0.bounds.midY }.max()! - verticalDates.map { $0.bounds.midY }.min()!
                if ySpan > xSpan * 2 {
                    return true
                }
            }

            return false
        }
    }

    static func supportsFile(at url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "pdf" else {
            return false
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return false
        }

        let hasTextLayer = (0..<document.pageCount).contains { pageIndex in
            guard let pageText = document.page(at: pageIndex)?.string else {
                return false
            }
            return !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return hasTextLayer && supportsSupportedTextLayout(document)
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

    private static func verticalDateSequence(in tokens: [TextLayerToken]) -> [TextLayerToken] {
        let sortedTokens = tokens.sorted {
            if abs($0.bounds.midX - $1.bounds.midX) > 0.03 {
                return $0.bounds.midX < $1.bounds.midX
            }
            return $0.bounds.midY > $1.bounds.midY
        }
        var bestSequence: [TextLayerToken] = []

        for startIndex in sortedTokens.indices {
            guard normalizedText(sortedTokens[startIndex].text) == "1" else { continue }

            let anchorX = sortedTokens[startIndex].bounds.midX
            var expectedDay = 1
            var sequence: [TextLayerToken] = []

            for token in sortedTokens[startIndex...] {
                guard abs(token.bounds.midX - anchorX) <= 0.04,
                      normalizedText(token.text) == String(expectedDay) else {
                    continue
                }

                sequence.append(token)
                expectedDay += 1
                if expectedDay > 31 { break }
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

        if let cells = rasterGridCells(matching: normalizedName, from: items, yearMonth: yearMonth) {
            return cells
        }

        if let cells = gridCells(matching: normalizedName, from: items, yearMonth: yearMonth) {
            return cells
        }

        if let cells = textLayerCells(matching: normalizedName, from: items, yearMonth: yearMonth) {
            return cells
        }

        return directTextCells(matching: normalizedName, from: items, yearMonth: yearMonth) ?? []
    }

    private struct RasterTableGrid {
        let pageIndex: Int
        let imageSize: CGSize
        let dayBoundaries: [CGFloat]
        let rows: [RasterTableRow]
    }

    private struct RasterTableRow {
        let name: String
        let dayValues: [String]
        let top: CGFloat
        let bottom: CGFloat
    }

    private struct RasterOCRText {
        let text: String
        let boundingBox: CGRect
    }

    private func rasterGridCells(
        matching normalizedName: String,
        from items: [RecognizedTextItem],
        yearMonth: YearMonth?
    ) -> [ExtractedShiftCell]? {
        let dayCount = yearMonth?.numberOfDays ?? 31

        for table in latestRasterTables {
            let row = table.rows.first(where: { row in
                let normalizedRowName = normalize(row.name)
                return normalizedRowName.hasPrefix(normalizedName)
                    || normalizedRowName.contains(normalizedName)
            }) ?? rasterRowClosestToName(
                normalizedName: normalizedName,
                items: items,
                in: table
            )
            guard let row else {
                continue
            }

            let values = Array(row.dayValues.prefix(dayCount))
            guard values.count == dayCount else { continue }

            return values.enumerated().map { index, value in
                let left = table.dayBoundaries[index]
                let right = table.dayBoundaries[index + 1]
                let minY = 1 - row.bottom / table.imageSize.height
                let height = (row.bottom - row.top) / table.imageSize.height

                return ExtractedShiftCell(
                    dateText: String(index + 1),
                    valueText: normalizedRasterShiftText(value),
                    pageIndex: table.pageIndex,
                    boundingBox: CGRect(
                        x: left / table.imageSize.width,
                        y: minY,
                        width: (right - left) / table.imageSize.width,
                        height: height
                    )
                )
            }
        }

        return nil
    }

    private func rasterRowClosestToName(
        normalizedName: String,
        items: [RecognizedTextItem],
        in table: RasterTableGrid
    ) -> RasterTableRow? {
        let nameItems = items.filter { item in
            item.rawPageText == nil && normalize(item.text).contains(normalizedName)
        }
        guard let nameItem = nameItems.min(by: { lhs, rhs in
            lhs.boundingBox.midX < rhs.boundingBox.midX
        }) else {
            return nil
        }

        let nameY = (1 - nameItem.boundingBox.midY) * table.imageSize.height
        return table.rows.min { lhs, rhs in
            abs(((lhs.top + lhs.bottom) / 2) - nameY)
                < abs(((rhs.top + rhs.bottom) / 2) - nameY)
        }
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
            if dateTokens.count >= dayCount {
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

            let verticalDates = Self.verticalDateSequence(
                in: pageTokens.map { TextLayerToken(text: $0.text, bounds: $0.boundingBox) }
            )
            guard verticalDates.count >= dayCount,
                  let target = targetTextLayerColumn(
                      matching: normalizedName,
                      in: pageTokens,
                      dateRows: verticalDates
                  ) else {
                continue
            }

            let columnTokens = pageTokens.filter { target.xRange.contains($0.boundingBox.midX) }
            let dateRows = verticalDates.prefix(dayCount).enumerated().map { index, token in
                DateRow(day: index + 1, centerY: token.bounds.midY, pageIndex: pageIndex)
            }
            let cells = dateRows.map { row in
                let range = dateCellRange(for: row, in: dateRows)
                let cellTokens = columnTokens
                    .filter { range.contains($0.boundingBox.midY) }
                    .sorted { lhs, rhs in
                        if let lhsOrder = lhs.textLayerOrder,
                           let rhsOrder = rhs.textLayerOrder,
                           lhsOrder != rhsOrder {
                            return lhsOrder < rhsOrder
                        }
                        return lhs.boundingBox.minY < rhs.boundingBox.minY
                    }
                let valueText = normalizedShiftText(cellTokens.map(\.text).joined())

                return ExtractedShiftCell(
                    dateText: String(row.day),
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

    private struct TextLayerColumn {
        let xRange: ClosedRange<CGFloat>
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

    private func targetTextLayerColumn(
        matching normalizedName: String,
        in pageTokens: [RecognizedTextItem],
        dateRows: [TextLayerToken]
    ) -> TextLayerColumn? {
        guard let firstDateY = dateRows.first?.bounds.midY else { return nil }
        let headerRows = rowGroups(from: pageTokens).filter { row in
            let centerY = row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
            return centerY > firstDateY + 0.01
        }

        let target = headerRows.compactMap { row -> (row: [RecognizedTextItem], bounds: CGRect)? in
            guard let bounds = nameBounds(in: row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }, matching: normalizedName) else {
                return nil
            }
            return (row, bounds)
        }.first

        let fallbackTarget = target ?? pageTokens.compactMap { item -> (row: [RecognizedTextItem], bounds: CGRect)? in
            guard normalize(item.text).contains(normalizedName) else { return nil }
            return ([item], item.boundingBox)
        }.first
        guard let target = fallbackTarget else { return nil }

        let referenceItems = target.row
        let centers = clusteredCoordinateCenters(
            referenceItems.map(\.boundingBox.midX).sorted(),
            maximumGap: 0.04
        )
        guard let targetIndex = centers.indices.min(by: { lhs, rhs in
            abs(centers[lhs] - target.bounds.midX) < abs(centers[rhs] - target.bounds.midX)
        }) else {
            return nil
        }

        let center = centers[targetIndex]
        let left = targetIndex > centers.startIndex
            ? (centers[targetIndex - 1] + center) / 2
            : max(0, target.bounds.minX - max(target.bounds.width, 0.03))
        let right = targetIndex + 1 < centers.endIndex
            ? (center + centers[targetIndex + 1]) / 2
            : min(1, target.bounds.maxX + max(target.bounds.width, 0.03))
        return TextLayerColumn(xRange: left...right)
    }

    private func clusteredCoordinateCenters(
        _ coordinates: [CGFloat],
        maximumGap: CGFloat
    ) -> [CGFloat] {
        guard let first = coordinates.first else { return [] }
        var clusters: [[CGFloat]] = [[first]]

        for coordinate in coordinates.dropFirst() {
            if coordinate - (clusters.last?.last ?? coordinate) <= maximumGap {
                clusters[clusters.index(before: clusters.endIndex)].append(coordinate)
            } else {
                clusters.append([coordinate])
            }
        }

        return clusters.map { values in
            values.reduce(0, +) / CGFloat(values.count)
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

    private func dateCellRange(
        for row: DateRow,
        in rows: [DateRow]
    ) -> ClosedRange<CGFloat> {
        let sortedRows = rows.sorted { $0.centerY > $1.centerY }
        guard let index = sortedRows.firstIndex(of: row) else {
            return row.centerY...row.centerY
        }

        let upperStep: CGFloat
        if index > sortedRows.startIndex {
            upperStep = sortedRows[index - 1].centerY - row.centerY
        } else if index + 1 < sortedRows.endIndex {
            upperStep = sortedRows[index].centerY - sortedRows[index + 1].centerY
        } else {
            upperStep = 0.05
        }

        let lowerStep: CGFloat
        if index + 1 < sortedRows.endIndex {
            lowerStep = row.centerY - sortedRows[index + 1].centerY
        } else if index > sortedRows.startIndex {
            lowerStep = sortedRows[index - 1].centerY - row.centerY
        } else {
            lowerStep = 0.05
        }

        return (row.centerY - lowerStep / 2)...(row.centerY + upperStep / 2)
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

    private func rasterTableGrid(from image: CGImage, pageIndex: Int) -> RasterTableGrid? {
        guard let buffer = RasterPixelBuffer(image: image) else { return nil }

        let verticalLines = rasterLineCenters(
            in: buffer,
            orientation: .vertical,
            threshold: 0.42
        )
        let horizontalLines = rasterLineCenters(
            in: buffer,
            orientation: .horizontal,
            threshold: 0.65
        )
        guard let dayBoundaries = regularLineRun(
            in: verticalLines,
            minimumCount: 32,
            maximumGapVariation: 0.28
        ),
        let rowBoundaries = staffRowLineRun(in: horizontalLines),
        dayBoundaries.count >= 32,
        rowBoundaries.count >= 3 else {
            return nil
        }

        let dayBoundaryValues = dayBoundaries.map { CGFloat($0) }
        let nameLeft = verticalLines.last { $0 < dayBoundaries[0] } ?? 0
        let dayStart = dayBoundaries[0]
        let rows = rowBoundaries.dropLast().compactMap { boundary -> RasterTableRow? in
            let top = boundary.0
            let bottom = boundary.1
            guard bottom - top > 8 else { return nil }

            let nameWidthPixels = max(dayStart - nameLeft, 1)
            let nameRect = CGRect(
                x: CGFloat(nameLeft),
                y: top,
                width: CGFloat(nameWidthPixels),
                height: bottom - top
            )
            guard let nameImage = image.cropping(to: nameRect) else {
                return nil
            }

            let nameObservations = rasterOCR(in: nameImage)
            let rowName = nameObservations
                .sorted { lhs, rhs in
                    lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .map(\.text)
                .joined()

            // OCR each cell independently. This prevents values from adjacent
            // days and notes below the table from being assigned to this row.
            let values = dayBoundaries.indices.dropLast().map { dayIndex in
                let left = CGFloat(dayBoundaries[dayIndex])
                let right = CGFloat(dayBoundaries[dayIndex + 1])
                let horizontalInset = max((right - left) * 0.10, 2)
                let verticalInset = max((bottom - top) * 0.08, 2)
                let cellRect = CGRect(
                    x: left + horizontalInset,
                    y: top + verticalInset,
                    width: max(right - left - horizontalInset * 2, 1),
                    height: max(bottom - top - verticalInset * 2, 1)
                )

                guard let cellImage = image.cropping(to: cellRect) else {
                    return ""
                }

                return rasterCellText(in: cellImage)
            }

            return RasterTableRow(
                name: rowName,
                dayValues: values,
                top: top,
                bottom: bottom
            )
        }

        guard rows.count >= 1 else { return nil }
        return RasterTableGrid(
            pageIndex: pageIndex,
            imageSize: CGSize(width: buffer.width, height: buffer.height),
            dayBoundaries: dayBoundaryValues,
            rows: rows
        )
    }

    private enum RasterLineOrientation {
        case vertical
        case horizontal
    }

    private struct RasterPixelBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(image: CGImage) {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            let bytesPerRow = image.width * 4
            var pixels = Array(repeating: UInt8(0), count: image.height * bytesPerRow)
            guard let context = CGContext(
                data: &pixels,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            width = image.width
            height = image.height
            bytes = pixels
        }

        func luminance(atX x: Int, y: Int) -> Int {
            let index = (y * width + x) * 4
            return Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
        }
    }

    private func rasterLineCenters(
        in buffer: RasterPixelBuffer,
        orientation: RasterLineOrientation,
        threshold: Double
    ) -> [Int] {
        let coordinateCount = orientation == .vertical ? buffer.width : buffer.height
        let sampleCount = orientation == .vertical ? buffer.height / 4 : buffer.width / 4
        guard coordinateCount > 0, sampleCount > 0 else { return [] }

        let minimumDarkSamples = Int(Double(sampleCount) * threshold)
        let candidateCoordinates = (0..<coordinateCount).compactMap { coordinate -> Int? in
            var darkSamples = 0
            if orientation == .vertical {
                for y in stride(from: 0, to: buffer.height, by: 4) {
                    if buffer.luminance(atX: coordinate, y: y) < 720 {
                        darkSamples += 1
                    }
                }
            } else {
                for x in stride(from: 0, to: buffer.width, by: 4) {
                    if buffer.luminance(atX: x, y: coordinate) < 720 {
                        darkSamples += 1
                    }
                }
            }

            return darkSamples >= minimumDarkSamples ? coordinate : nil
        }

        return clusteredCenters(candidateCoordinates)
    }

    private func clusteredCenters(_ coordinates: [Int]) -> [Int] {
        guard let first = coordinates.first else { return [] }
        var clusters: [[Int]] = [[first]]

        for coordinate in coordinates.dropFirst() {
            if coordinate - (clusters.last?.last ?? coordinate) <= 4 {
                clusters[clusters.index(before: clusters.endIndex)].append(coordinate)
            } else {
                clusters.append([coordinate])
            }
        }

        return clusters.map { values in
            values[values.count / 2]
        }
    }

    private func regularLineRun(
        in centers: [Int],
        minimumCount: Int,
        maximumGapVariation: Double
    ) -> [Int]? {
        guard centers.count >= minimumCount else { return nil }
        var bestRun: [Int] = []

        for startIndex in centers.indices {
            var run = [centers[startIndex]]
            var expectedGap: Double?

            for index in centers.index(after: startIndex)..<centers.endIndex {
                let gap = centers[index] - centers[index - 1]
                if let expectedGap {
                    let variation = abs(Double(gap) - expectedGap) / expectedGap
                    guard variation <= maximumGapVariation else { break }
                } else {
                    expectedGap = Double(gap)
                }
                run.append(centers[index])
            }

            if run.count > bestRun.count {
                bestRun = run
            }
        }

        guard bestRun.count >= minimumCount else { return nil }
        return Array(bestRun.prefix(minimumCount + 1))
    }

    private func staffRowLineRun(in centers: [Int]) -> [(CGFloat, CGFloat)]? {
        guard centers.count >= 4 else { return nil }
        let gaps = zip(centers.dropFirst(), centers).map { current, previous in
            current - previous
        }
        let sortedGaps = gaps.sorted()
        let medianGap = Double(sortedGaps[sortedGaps.count / 2])
        let candidateStart = gaps.indices
            .filter { index in
                Double(gaps[index]) > medianGap * 1.45
            }
            .max { lhs, rhs in
                gaps[lhs] < gaps[rhs]
            }

        let startIndex = candidateStart.map { centers.index(after: $0) } ?? centers.startIndex
        let rowCenters = Array(centers[startIndex...])
        guard rowCenters.count >= 3 else { return nil }

        return zip(rowCenters.dropFirst(), rowCenters).map { pair in
            (CGFloat(pair.1), CGFloat(pair.0))
        }
    }

    private func rasterOCR(
        in image: CGImage,
        minimumTextHeight: Float = 0.01,
        recognitionLanguages: [String] = ["ja-JP", "en-US"],
        customWords: [String] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "△", "□", "休", "年"]
    ) -> [RasterOCRText] {
        guard let scaledImage = scaledRasterImage(image, scale: 3) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = false
        request.customWords = customWords
        request.minimumTextHeight = minimumTextHeight

        do {
            try VNImageRequestHandler(cgImage: scaledImage, options: [:]).perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(5).map(\.string)
            guard let text = bestRasterOCRCandidate(from: candidates),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return RasterOCRText(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                boundingBox: observation.boundingBox
            )
        }
    }

    private func bestRasterOCRCandidate(from candidates: [String]) -> String? {
        candidates
            .map { candidate in
                let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                let japaneseCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
                    let value = scalar.value
                    if (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value) {
                        count += 1
                    }
                }
                let shiftSymbolCount = text.filter { "休年△□①②③④⑤⑥⑦⑧⑨".contains($0) }.count
                let suspiciousLatinCount = text.filter { "LlIiZz".contains($0) }.count

                return (japaneseCount * 4) + (shiftSymbolCount * 5) - (suspiciousLatinCount * 2)
            }
            .enumerated()
            .max { lhs, rhs in
                if lhs.element != rhs.element {
                    return lhs.element < rhs.element
                }
                return lhs.offset > rhs.offset
            }
            .map { candidates[$0.offset] }
    }

    private func rasterCellText(in image: CGImage) -> String {
        let primaryText = rasterOCR(in: image)
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.05 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .map(\.text)
            .joined()

        let mayBeCircledOne = primaryText == "祝" || primaryText == "祝★"
        let mayBePlainOne = ["0", "O", "o", "1", "I", "l", "i", "①", "01", "O1", "o1", "(1)"].contains(primaryText)
        if mayBePlainOne, looksLikeCircledDigit(in: image) {
            return "①"
        }
        if primaryText.isEmpty, looksLikeCircledDigit(in: image) {
            return "①"
        }
        guard primaryText.isEmpty || mayBeCircledOne else { return primaryText }

        // Vision frequently recognizes the circled 1 used in this table as
        // the standalone holiday glyph "祝". A standalone 祝 is not a valid
        // shift value for this scanner, so preserve the circled-number value
        // instead of dropping it during normalization.
        if mayBeCircledOne {
            return "①"
        }

        let alternateText = rasterOCR(
            in: image,
            minimumTextHeight: 0.0001,
            recognitionLanguages: ["en-US"],
            customWords: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
        )
        let alternateValue = alternateText.map(\.text).joined()

        // Circled shift numbers are small and can disappear at the normal
        // threshold. Retry only an empty cell and accept the retry when it
        // produced a circled number, avoiding noise in genuinely empty cells.
        let retryText = rasterOCR(in: image, minimumTextHeight: 0.0001)
            .map(\.text)
            .joined()
        let circledText = retryText.filter { "①②③④⑤⑥⑦⑧⑨".contains($0) }
        if !circledText.isEmpty {
            return circledText
        }
        if ["1", "I", "l", "i"].contains(alternateValue) {
            return "①"
        }
        if mayBeCircledOne && looksLikeCircledDigit(in: image) {
            return "①"
        }
        return ["1", "I", "l", "i"].contains(retryText) ? "①" : ""
    }

    private func looksLikeCircledDigit(in image: CGImage) -> Bool {
        guard let buffer = RasterPixelBuffer(image: image),
              buffer.width >= 12,
              buffer.height >= 12 else {
            return false
        }

        let threshold = 720
        var darkPixels = Set<Int>()
        for y in 2..<(buffer.height - 2) {
            for x in 2..<(buffer.width - 2) {
                if buffer.luminance(atX: x, y: y) < threshold {
                    darkPixels.insert(y * buffer.width + x)
                }
            }
        }

        var visited = Set<Int>()
        for seed in darkPixels {
            guard !visited.contains(seed) else { continue }

            var queue = [seed]
            var component: [CGPoint] = []
            visited.insert(seed)
            var cursor = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % buffer.width
                let y = index / buffer.width
                component.append(CGPoint(x: x, y: y))

                for offsetY in -1...1 {
                    for offsetX in -1...1 {
                        guard offsetX != 0 || offsetY != 0 else { continue }
                        let neighborX = x + offsetX
                        let neighborY = y + offsetY
                        guard neighborX >= 2,
                              neighborX < buffer.width - 2,
                              neighborY >= 2,
                              neighborY < buffer.height - 2 else {
                            continue
                        }

                        let neighbor = neighborY * buffer.width + neighborX
                        guard darkPixels.contains(neighbor), !visited.contains(neighbor) else {
                            continue
                        }

                        visited.insert(neighbor)
                        queue.append(neighbor)
                    }
                }
            }

            guard component.count >= 12,
                  let minXValue = component.map(\.x).min(),
                  let maxXValue = component.map(\.x).max(),
                  let minYValue = component.map(\.y).min(),
                  let maxYValue = component.map(\.y).max() else {
                continue
            }

            let minX = Int(minXValue)
            let maxX = Int(maxXValue)
            let minY = Int(minYValue)
            let maxY = Int(maxYValue)

            let width = maxX - minX + 1
            let height = maxY - minY + 1
            let aspectRatio = Double(width) / Double(height)
            guard width >= 8,
                  height >= 8,
                  (0.65...1.35).contains(aspectRatio) else {
                continue
            }

            func containsDarkPixel(nearX x: Double, nearY y: Double) -> Bool {
                let xStart = max(Int(x - 2), minX)
                let xEnd = min(Int(x + 2), maxX)
                let yStart = max(Int(y - 2), minY)
                let yEnd = min(Int(y + 2), maxY)
                for sampleY in yStart...yEnd {
                    for sampleX in xStart...xEnd {
                        if darkPixels.contains(sampleY * buffer.width + sampleX) {
                            return true
                        }
                    }
                }
                return false
            }

            let centerX = Double(minX + maxX) / 2
            let centerY = Double(minY + maxY) / 2
            let cardinalMatches = stride(from: 0.42, through: 0.50, by: 0.02).map { radiusFactor in
                let radiusX = Double(width) * radiusFactor
                let radiusY = Double(height) * radiusFactor
                let cardinalPoints = [
                    (centerX, centerY - radiusY),
                    (centerX + radiusX, centerY),
                    (centerX, centerY + radiusY),
                    (centerX - radiusX, centerY)
                ]
                return cardinalPoints.filter {
                    containsDarkPixel(nearX: $0.0, nearY: $0.1)
                }.count
            }.max() ?? 0

            if cardinalMatches >= 3 {
                return true
            }
        }

        return false
    }

    private func scaledRasterImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
            .replacingOccurrences(of: "a", with: "△")
            .replacingOccurrences(of: "▲", with: "△")

        if normalized == "祝" {
            normalized = ""
        }

        return normalized
    }

    private func normalizedRasterShiftText(_ text: String) -> String {
        var normalized = normalizedShiftText(normalize(text))
            .replacingOccurrences(of: "／", with: "/")

        // Vision can mistake small shift symbols and separators for Latin
        // glyphs or digits after a raster cell has been cropped.
        if normalized == "L7" || normalized == "I7" || normalized == "l7" {
            return "△1"
        }
        if normalized == "L2" || normalized == "I2" || normalized == "l2" {
            return "△2"
        }
        if normalized == "27" {
            return "2フ"
        }
        if normalized == "半年5" || normalized == "半年15" {
            return "半年/5"
        }
        if normalized.hasPrefix("2") && normalized.hasSuffix("会議") {
            normalized = "2/会議"
        }
        if normalized.hasPrefix("2勤務") && normalized.hasSuffix("委") && !normalized.contains("/") {
            let suffix = String(normalized.dropFirst("2勤務".count))
            normalized = "2勤務/" + suffix
        }
        if normalized == "2勤務/倭委" {
            normalized = "2勤務/委"
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
            return "文字情報を持つPDFに対応しています"
        case .missingTextLayer:
            return "文字データを持つPDFではありません"
        case .unsupportedLayout:
            return "横型または縦型のPDFのみ対応しています"
        case .unreadableFile:
            return "勤務表ファイルを開けませんでした。"
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
