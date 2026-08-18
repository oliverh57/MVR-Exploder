import AppKit
import CoreGraphics

enum PatchPDFLayout {
    case byFixtureType
    case byFixtureID
}

enum MVRPatchPDFExportError: Error {
    case cannotCreateFile
    case cannotCreateContext
}

/// Renders a patch list to a paginated PDF via a raw CGPDFContext — drawn
/// manually rather than via PDFKit (which is built for reading/displaying
/// PDFs, not authoring multi-page ones) or a single flattened NSView
/// snapshot (which can't paginate a long fixture list).
enum MVRPatchPDFExporter {
    private struct Row {
        let fixtureID: String
        let fixtureType: String
        let mode: String
        let universe: String
        let address: String
    }

    private static let columnTitles = ["Fixture ID", "Fixture Type", "Mode", "Universe", "Address"]
    private static let columnWidths: [CGFloat] = [70, 210, 120, 66, 66]

    static func export(fixtures: [MVRFixture], layout: PatchPDFLayout, documentTitle: String, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw MVRPatchPDFExportError.cannotCreateFile
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter portrait
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MVRPatchPDFExportError.cannotCreateContext
        }
        let pageRect = mediaBox

        // NSAttributedString's drawing methods render into whatever
        // NSGraphicsContext is "current" — without pushing one that wraps
        // this CGContext, text silently draws nowhere while shapes/lines
        // drawn directly via CGContext calls still work fine.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let margin: CGFloat = 40
        let columnWidths = Self.columnWidths
        var columnX: [CGFloat] = []
        var runningX = margin
        for width in columnWidths {
            columnX.append(runningX)
            runningX += width
        }

        let contentTop = pageRect.height - margin
        let footerHeight: CGFloat = 22
        let contentBottom = margin + footerHeight
        let rowHeight: CGFloat = 18
        let headerRowHeight: CGFloat = 22
        let groupHeaderHeight: CGFloat = 24

        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        let subtitleFont = NSFont.systemFont(ofSize: 11)
        let columnHeaderFont = NSFont.boldSystemFont(ofSize: 10)
        let groupFont = NSFont.boldSystemFont(ofSize: 13)
        let bodyFont = NSFont.systemFont(ofSize: 10)
        let footerFont = NSFont.systemFont(ofSize: 9)

        let sortedRows = sortedByFixtureID(fixtures).map(row(for:))
        let groups = groupedByFixtureType(fixtures).map { (type: $0.type, rows: $0.rows.map(row(for:))) }

        /// Lays the document out once. With `measuring` true nothing is
        /// drawn and only the page count is returned, so the real pass can
        /// print "Page N of M" — pagination depends purely on cursor
        /// arithmetic, so both passes break pages identically.
        func run(measuring: Bool, totalPages: Int) -> Int {
            var cursorY: CGFloat = 0
            var pageIndex = 0
            var rowParity = 0

            func draw(_ text: String, at point: CGPoint, width: CGFloat, font: NSFont, color: NSColor = .black) {
                guard !measuring else { return }
                let clipped = truncated(text, toFit: width - 6, font: font)
                NSAttributedString(string: clipped, attributes: [.font: font, .foregroundColor: color])
                    .draw(at: point)
            }

            func drawFooter() {
                guard !measuring else { return }
                let text = "Page \(pageIndex) of \(totalPages)"
                let attributes: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: NSColor.darkGray]
                let width = (text as NSString).size(withAttributes: attributes).width
                NSAttributedString(string: text, attributes: attributes)
                    .draw(at: CGPoint(x: (pageRect.width - width) / 2, y: margin))
            }

            func drawColumnHeaders() {
                for (index, header) in Self.columnTitles.enumerated() {
                    draw(header, at: CGPoint(x: columnX[index], y: cursorY), width: columnWidths[index], font: columnHeaderFont)
                }
                if !measuring {
                    context.saveGState()
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                    context.setLineWidth(0.75)
                    context.move(to: CGPoint(x: margin, y: cursorY - 4))
                    context.addLine(to: CGPoint(x: pageRect.width - margin, y: cursorY - 4))
                    context.strokePath()
                    context.restoreGState()
                }
                cursorY -= headerRowHeight
            }

            func startPage() {
                if !measuring { context.beginPDFPage(nil) }
                pageIndex += 1
                cursorY = contentTop
                if pageIndex == 1 {
                    draw(documentTitle, at: CGPoint(x: margin, y: cursorY), width: pageRect.width - 2 * margin, font: titleFont)
                    cursorY -= 22
                    let fixtureWord = fixtures.count == 1 ? "fixture" : "fixtures"
                    draw("\(fixtures.count) \(fixtureWord)", at: CGPoint(x: margin, y: cursorY), width: pageRect.width - 2 * margin, font: subtitleFont, color: .darkGray)
                    cursorY -= 26
                }
                drawColumnHeaders()
            }

            func endPage() {
                drawFooter()
                if !measuring { context.endPDFPage() }
            }

            func ensureSpace(_ needed: CGFloat) {
                if cursorY - needed < contentBottom {
                    endPage()
                    startPage()
                }
            }

            func drawRow(_ row: Row) {
                ensureSpace(rowHeight)
                if rowParity % 2 == 0 && !measuring {
                    context.saveGState()
                    context.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
                    // draw(at:) places text on its baseline, so the band is
                    // offset to sit centred on the line rather than below it.
                    context.fill(CGRect(x: margin, y: cursorY - 4, width: pageRect.width - 2 * margin, height: rowHeight))
                    context.restoreGState()
                }
                rowParity += 1
                let values = [row.fixtureID, row.fixtureType, row.mode, row.universe, row.address]
                for (index, value) in values.enumerated() {
                    draw(value, at: CGPoint(x: columnX[index], y: cursorY), width: columnWidths[index], font: bodyFont)
                }
                cursorY -= rowHeight
            }

            func drawGroupHeader(_ title: String) {
                // Keep a header from being stranded alone at the bottom of a page.
                ensureSpace(groupHeaderHeight + rowHeight)
                cursorY -= 6
                draw(title, at: CGPoint(x: margin, y: cursorY), width: pageRect.width - 2 * margin, font: groupFont)
                cursorY -= groupHeaderHeight
                rowParity = 0
            }

            startPage()
            switch layout {
            case .byFixtureID:
                for row in sortedRows { drawRow(row) }
            case .byFixtureType:
                for group in groups {
                    drawGroupHeader(group.type.isEmpty ? "(no fixture type)" : group.type)
                    for row in group.rows { drawRow(row) }
                }
            }
            endPage()
            return pageIndex
        }

        let totalPages = run(measuring: true, totalPages: 0)
        _ = run(measuring: false, totalPages: totalPages)
        context.closePDF()
    }

    /// `universe` / `channel` come straight off MVRFixture, so the PDF
    /// shows the same derived patch values (and the same "-" for unpatched
    /// fixtures) as the fixture table and 3D hover card.
    private static func row(for fixture: MVRFixture) -> Row {
        Row(
            fixtureID: fixture.currentFixtureID.map(String.init) ?? "-",
            fixtureType: fixture.gdtfSpec,
            mode: fixture.mode,
            universe: fixture.universe,
            address: fixture.channel
        )
    }

    /// Ascending by Fixture ID; fixtures with no ID sort to the end
    /// (alphabetically by name) rather than to the front, which reads more
    /// naturally in a printed patch list than the table view's own
    /// sort-to-Int.min convention.
    private static func sortedByFixtureID(_ fixtures: [MVRFixture]) -> [MVRFixture] {
        fixtures.sorted { a, b in
            switch (a.currentFixtureID, b.currentFixtureID) {
            case let (idA?, idB?): return idA < idB
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    private static func groupedByFixtureType(_ fixtures: [MVRFixture]) -> [(type: String, rows: [MVRFixture])] {
        let grouped = Dictionary(grouping: fixtures, by: \.gdtfSpec)
        return grouped.keys.sorted().map { key in (key, sortedByFixtureID(grouped[key] ?? [])) }
    }

    private static func truncated(_ text: String, toFit width: CGFloat, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attrs).width <= width { return text }
        var trimmed = text
        while !trimmed.isEmpty {
            trimmed.removeLast()
            let candidate = trimmed + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= width {
                return candidate
            }
        }
        return "…"
    }
}
