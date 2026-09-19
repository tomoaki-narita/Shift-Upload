import CoreGraphics
import PDFKit

final class ShiftPDFGridDetector {
    func detect(
        in document: PDFDocument,
        textItems: [RecognizedTextItem],
        dayCount: Int
    ) -> [PDFTableGrid] {
        (0..<document.pageCount).compactMap { pageIndex in
            guard let page = document.page(at: pageIndex) else { return nil }

            let pageItems = textItems.filter {
                $0.pageIndex == pageIndex && $0.rawPageText == nil
            }
            let dateColumns = dateColumns(in: pageItems, dayCount: dayCount, pageIndex: pageIndex)
            guard dateColumns.count == dayCount else { return nil }

            let lineSegments = lineSegments(in: page)
            guard let grid = makeGrid(
                from: lineSegments,
                dateColumns: dateColumns,
                textItems: pageItems,
                dayCount: dayCount,
                pageIndex: pageIndex
            ) else {
                return nil
            }

            return grid
        }
    }

    fileprivate struct LineSegment {
        let start: CGPoint
        let end: CGPoint
    }

    private struct GroupedLine {
        let coordinate: CGFloat
        let intervals: [ClosedRange<CGFloat>]

        func coverage(in range: ClosedRange<CGFloat>) -> CGFloat {
            intervals.reduce(0) { total, interval in
                let lower = max(interval.lowerBound, range.lowerBound)
                let upper = min(interval.upperBound, range.upperBound)
                return total + max(0, upper - lower)
            }
        }
    }

    private struct GridBand {
        let lower: CGFloat
        let upper: CGFloat
        let hasNameText: Bool
        let hasDayText: Bool
    }

    fileprivate struct ScanState {
        var currentPoint = CGPoint.zero
        var segments: [LineSegment] = []
    }

    private func lineSegments(in page: PDFPage) -> [LineSegment] {
        guard let pageRef = page.pageRef,
              let table = CGPDFOperatorTableCreate() else {
            return []
        }

        let state = ScanStateBox()
        let pointer = Unmanaged.passUnretained(state).toOpaque()

        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanStateBox>.fromOpaque(info).takeUnretainedValue()
            guard let point = popPDFPoint(from: scanner) else { return }
            state.value.currentPoint = point
        }

        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanStateBox>.fromOpaque(info).takeUnretainedValue()
            guard let point = popPDFPoint(from: scanner) else { return }
            state.value.segments.append(LineSegment(start: state.value.currentPoint, end: point))
            state.value.currentPoint = point
        }

        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<ScanStateBox>.fromOpaque(info).takeUnretainedValue()
            var height: CGPDFReal = 0
            var width: CGPDFReal = 0
            var y: CGPDFReal = 0
            var x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &height),
                  CGPDFScannerPopNumber(scanner, &width),
                  CGPDFScannerPopNumber(scanner, &y),
                  CGPDFScannerPopNumber(scanner, &x) else {
                return
            }

            let origin = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let oppositeX = origin.x + CGFloat(width)
            let oppositeY = origin.y + CGFloat(height)
            state.value.segments.append(contentsOf: [
                LineSegment(start: origin, end: CGPoint(x: oppositeX, y: origin.y)),
                LineSegment(start: CGPoint(x: oppositeX, y: origin.y), end: CGPoint(x: oppositeX, y: oppositeY)),
                LineSegment(start: CGPoint(x: oppositeX, y: oppositeY), end: CGPoint(x: origin.x, y: oppositeY)),
                LineSegment(start: CGPoint(x: origin.x, y: oppositeY), end: origin)
            ])
        }

        let contentStream = CGPDFContentStreamCreateWithPage(pageRef)
        let scanner = CGPDFScannerCreate(contentStream, table, pointer)

        CGPDFScannerScan(scanner)
        return state.value.segments
    }

    private func dateColumns(
        in items: [RecognizedTextItem],
        dayCount: Int,
        pageIndex: Int
    ) -> [DateColumn] {
        let sortedItems = items.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        var bestSequence: [RecognizedTextItem] = []
        for startIndex in sortedItems.indices {
            guard normalizedText(sortedItems[startIndex].text) == "1" else { continue }

            var expectedDay = 1
            var sequence: [RecognizedTextItem] = []
            for item in sortedItems[startIndex...] {
                guard normalizedText(item.text) == String(expectedDay) else { continue }
                sequence.append(item)
                expectedDay += 1
                if expectedDay > dayCount { break }
            }

            if sequence.count > bestSequence.count {
                bestSequence = sequence
            }
        }

        guard bestSequence.count == dayCount else { return [] }
        return bestSequence.enumerated().map { index, item in
            DateColumn(day: index + 1, centerX: item.boundingBox.midX, pageIndex: pageIndex)
        }
    }

    private func makeGrid(
        from segments: [LineSegment],
        dateColumns: [DateColumn],
        textItems: [RecognizedTextItem],
        dayCount: Int,
        pageIndex: Int
    ) -> PDFTableGrid? {
        let verticalLines = groupedLines(from: segments, vertical: true)
        let horizontalLines = groupedLines(from: segments, vertical: false)
        guard !verticalLines.isEmpty, !horizontalLines.isEmpty else { return nil }

        let dateEdges = dateColumns.compactMap { column -> (left: CGFloat, right: CGFloat)? in
            guard let left = verticalLines
                    .map(\.coordinate)
                    .filter({ $0 < column.centerX - 0.5 })
                    .max(),
                  let right = verticalLines
                    .map(\.coordinate)
                    .filter({ $0 > column.centerX + 0.5 })
                    .min() else {
                return nil
            }
            return (left, right)
        }
        guard dateEdges.count == dayCount else { return nil }

        let firstDayLeft = dateEdges[0].left
        guard let dataRight = dateEdges.last?.right else {
            return nil
        }

        let dateCenters = dateColumns.map(\.centerX)
        let averageDateStep = zip(dateCenters.dropFirst(), dateCenters)
            .map(-)
            .reduce(0, +) / CGFloat(max(dateCenters.count - 1, 1))
        // Numbers omits some left borders from the content stream. The name
        // column is therefore estimated from the regular day-cell width when
        // its own border is unavailable.
        let nameLeft = verticalLines
            .map(\.coordinate)
            .filter({ $0 < firstDayLeft - 0.5 })
            .filter({ $0 <= firstDayLeft - averageDateStep * 1.5 })
            .max()
            ?? firstDayLeft - averageDateStep * 2.2

        let tableRange = nameLeft...dataRight
        let horizontalCoordinates = horizontalLines
            .filter { $0.coverage(in: tableRange) >= (dataRight - nameLeft) * 0.75 }
            .map(\.coordinate)
            .sorted()
        guard horizontalCoordinates.count >= 3 else { return nil }

        let bands = zip(horizontalCoordinates, horizontalCoordinates.dropFirst()).map { lower, upper in
            let nameBounds = CGRect(
                x: nameLeft,
                y: lower,
                width: firstDayLeft - nameLeft,
                height: upper - lower
            )
            let dayBounds = dateEdges.map { edge in
                CGRect(x: edge.left, y: lower, width: edge.right - edge.left, height: upper - lower)
            }
            let textInBounds: (CGRect) -> [RecognizedTextItem] = { bounds in
                textItems.filter { bounds.contains($0.boundingBox.midXMidY) }
            }
            let nameText = textInBounds(nameBounds).filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.text.allSatisfy { $0.isNumber }
            }
            let hasDayText = dayBounds.contains { bounds in
                !textInBounds(bounds).isEmpty
            }
            return GridBand(
                lower: lower,
                upper: upper,
                hasNameText: !nameText.isEmpty,
                hasDayText: hasDayText
            )
        }

        var logicalBands: [(lower: CGFloat, upper: CGFloat)] = []
        for band in bands.sorted(by: { $0.upper > $1.upper }) {
            if band.hasNameText {
                logicalBands.append((band.lower, band.upper))
            } else if band.hasDayText, !logicalBands.isEmpty {
                let lastIndex = logicalBands.index(before: logicalBands.endIndex)
                logicalBands[lastIndex].lower = min(logicalBands[lastIndex].lower, band.lower)
            }
        }

        let rows = logicalBands.map { lower, upper in
            let rowBounds = CGRect(
                x: nameLeft,
                y: lower,
                width: dataRight - nameLeft,
                height: upper - lower
            )
            let nameCell = PDFGridCell(day: nil, bounds: CGRect(
                x: nameLeft,
                y: lower,
                width: firstDayLeft - nameLeft,
                height: upper - lower
            ))
            let dayCells = dateEdges.enumerated().map { index, edge in
                PDFGridCell(
                    day: index + 1,
                    bounds: CGRect(x: edge.left, y: lower, width: edge.right - edge.left, height: upper - lower)
                )
            }
            return PDFGridRow(bounds: rowBounds, nameCell: nameCell, dayCells: dayCells)
        }

        guard !rows.isEmpty else { return nil }
        return PDFTableGrid(
            pageIndex: pageIndex,
            bounds: CGRect(x: nameLeft, y: horizontalCoordinates.first!, width: dataRight - nameLeft, height: horizontalCoordinates.last! - horizontalCoordinates.first!),
            rows: rows
        )
    }

    private func groupedLines(from segments: [LineSegment], vertical: Bool) -> [GroupedLine] {
        let candidates = segments.compactMap { segment -> (coordinate: CGFloat, interval: ClosedRange<CGFloat>)? in
            let dx = abs(segment.end.x - segment.start.x)
            let dy = abs(segment.end.y - segment.start.y)
            if vertical {
                guard dx <= 0.75, dy >= 5 else { return nil }
                return (segment.start.x, min(segment.start.y, segment.end.y)...max(segment.start.y, segment.end.y))
            } else {
                guard dy <= 0.75, dx >= 5 else { return nil }
                return (segment.start.y, min(segment.start.x, segment.end.x)...max(segment.start.x, segment.end.x))
            }
        }

        var groups: [(coordinate: CGFloat, intervals: [ClosedRange<CGFloat>])] = []
        for candidate in candidates.sorted(by: { $0.coordinate < $1.coordinate }) {
            guard let index = groups.firstIndex(where: { abs($0.coordinate - candidate.coordinate) <= 1.0 }) else {
                groups.append((candidate.coordinate, [candidate.interval]))
                continue
            }
            groups[index].intervals.append(candidate.interval)
            groups[index].coordinate = (groups[index].coordinate + candidate.coordinate) / 2
        }

        return groups.map { group in
            let mergedIntervals = group.intervals
                .sorted { $0.lowerBound < $1.lowerBound }
                .reduce(into: [ClosedRange<CGFloat>]()) { result, interval in
                    guard let last = result.last else {
                        result.append(interval)
                        return
                    }
                    if interval.lowerBound <= last.upperBound + 1.5 {
                        result[result.index(before: result.endIndex)] = last.lowerBound...max(last.upperBound, interval.upperBound)
                    } else {
                        result.append(interval)
                    }
                }
            return GroupedLine(coordinate: group.coordinate, intervals: mergedIntervals)
        }
    }

    private func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ScanStateBox {
    var value = ShiftPDFGridDetector.ScanState()
}

private extension CGRect {
    var midXMidY: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private func popPDFPoint(from scanner: CGPDFScannerRef) -> CGPoint? {
    var y: CGPDFReal = 0
    var x: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else {
        return nil
    }
    return CGPoint(x: CGFloat(x), y: CGFloat(y))
}
