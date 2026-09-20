import Foundation
import CoreGraphics

struct RecognizedTextItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect
    let pageIndex: Int
    let rawPageText: String?
    let textLayerOrder: Int?

    var positionDescription: String {
        let x = String(format: "%.2f", boundingBox.midX)
        let y = String(format: "%.2f", boundingBox.midY)
        return "Page \(pageIndex + 1) / x \(x) / y \(y)"
    }
}

struct ExtractedShiftCell: Identifiable, Equatable {
    let id = UUID()
    let dateText: String
    let valueText: String
    let pageIndex: Int
    let boundingBox: CGRect
}

struct DateColumn: Equatable {
    let day: Int
    let centerX: CGFloat
    let pageIndex: Int
}

struct DateRow: Equatable {
    let day: Int
    let centerY: CGFloat
    let pageIndex: Int
}

struct PDFGridCell: Equatable {
    let day: Int?
    let bounds: CGRect
}

struct PDFGridRow: Equatable {
    let bounds: CGRect
    let nameCell: PDFGridCell
    let dayCells: [PDFGridCell]
}

struct PDFTableGrid: Equatable {
    let pageIndex: Int
    let bounds: CGRect
    let rows: [PDFGridRow]
}
