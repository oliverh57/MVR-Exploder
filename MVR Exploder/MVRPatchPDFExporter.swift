import AppKit
import CoreGraphics

enum PatchPDFLayout {
    case byFixtureType
    case byFixtureID
}

/// How the PDF's pages are set up.
struct PatchPDFPageSetup: Equatable {
    enum Paper: String, CaseIterable, Identifiable {
        case a4
        case letter
        /// One continuous page, A4 wide and as tall as the list — for
        /// reading on a screen, where page breaks only get in the way.
        case pageless

        var id: String { rawValue }
        var label: String {
            switch self {
            case .a4: return "A4"
            case .letter: return "US Letter"
            case .pageless: return "Pageless"
            }
        }
        /// Portrait, in points. Pageless is A4 wide; its height is worked
        /// out from the list.
        var size: CGSize {
            self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// Applied to every font and row height. Medium is the size the
        /// list has always been printed at.
        var scale: CGFloat {
            switch self {
            case .small: return 0.85
            case .medium: return 1
            case .large: return 1.25
            }
        }
    }

    var paper: Paper = .letter
    var textSize: TextSize = .medium
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

    /// - Parameter stageImage: a render of the rig to lead with, on a
    ///   landscape first page of its own. Nil for a patch list only.
    static func export(
        fixtures: [MVRFixture], layout: PatchPDFLayout, documentTitle: String,
        stageImage: NSImage? = nil, setup: PatchPDFPageSetup = PatchPDFPageSetup(),
        to url: URL
    ) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw MVRPatchPDFExportError.cannotCreateFile
        }
        var mediaBox = CGRect(origin: .zero, size: setup.paper.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MVRPatchPDFExportError.cannotCreateContext
        }
        var pageRect = mediaBox
        let pageless = setup.paper == .pageless

        // NSAttributedString's drawing methods render into whatever
        // NSGraphicsContext is "current" — without pushing one that wraps
        // this CGContext, text silently draws nowhere while shapes/lines
        // drawn directly via CGContext calls still work fine.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let margin: CGFloat = 40
        // The columns keep their proportions and fill whatever width the
        // paper leaves between the margins.
        let columnScale = (pageRect.width - 2 * margin) / Self.columnWidths.reduce(0, +)
        let columnWidths = Self.columnWidths.map { $0 * columnScale }
        let text = setup.textSize.scale
        var columnX: [CGFloat] = []
        var runningX = margin
        for width in columnWidths {
            columnX.append(runningX)
            runningX += width
        }

        var contentTop = pageRect.height - margin
        let footerHeight: CGFloat = 22
        let contentBottom = margin + footerHeight
        let rowHeight: CGFloat = 18 * text
        let headerRowHeight: CGFloat = 22 * text
        let groupHeaderHeight: CGFloat = 24 * text

        let titleFont = NSFont.boldSystemFont(ofSize: 18 * text)
        let subtitleFont = NSFont.systemFont(ofSize: 11 * text)
        let columnHeaderFont = NSFont.boldSystemFont(ofSize: 10 * text)
        let groupFont = NSFont.boldSystemFont(ofSize: 13 * text)
        let bodyFont = NSFont.systemFont(ofSize: 10 * text)
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

            /// Page 1 when there's a render: the stage, landscape, with the
            /// title over it. The patch list starts on the page after.
            func drawStagePage(_ image: NSImage) {
                pageIndex += 1
                guard !measuring else { return }

                let landscape = CGRect(x: 0, y: 0, width: pageRect.height, height: pageRect.width)
                var box = landscape
                let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
                context.beginPDFPage(info as CFDictionary)

                var top = landscape.height - margin
                NSAttributedString(string: documentTitle, attributes: [.font: titleFont, .foregroundColor: NSColor.black])
                    .draw(at: CGPoint(x: margin, y: top - 18 * text))
                top -= 26 * text
                let fixtureWord = fixtures.count == 1 ? "fixture" : "fixtures"
                NSAttributedString(
                    string: "\(fixtures.count) \(fixtureWord)",
                    attributes: [.font: subtitleFont, .foregroundColor: NSColor.darkGray])
                    .draw(at: CGPoint(x: margin, y: top - 12))
                top -= 22 * text

                // Fitted into what's left, keeping the render's shape, with
                // a line kept free under it for the caption.
                let captionHeight: CGFloat = 18
                let area = CGRect(
                    x: margin, y: margin + footerHeight + captionHeight,
                    width: landscape.width - 2 * margin,
                    height: top - margin - footerHeight - captionHeight)
                let scale = min(area.width / image.size.width, area.height / image.size.height)
                let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let frame = CGRect(
                    x: area.midX - drawn.width / 2, y: area.maxY - drawn.height,
                    width: drawn.width, height: drawn.height)
                image.draw(in: frame)

                // Said on the page, because a render looks like a drawing:
                // it isn't to scale and isn't the plot of record — the list
                // that follows is.
                let caption = "3D view for reference only. Not to scale."
                let captionAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFontManager.shared.convert(footerFont, toHaveTrait: .italicFontMask),
                    .foregroundColor: NSColor.darkGray,
                ]
                let captionWidth = (caption as NSString).size(withAttributes: captionAttributes).width
                NSAttributedString(string: caption, attributes: captionAttributes)
                    .draw(at: CGPoint(x: frame.midX - captionWidth / 2, y: frame.minY - 14))

                let footer = "Page \(pageIndex) of \(totalPages)"
                let attributes: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: NSColor.darkGray]
                let width = (footer as NSString).size(withAttributes: attributes).width
                NSAttributedString(string: footer, attributes: attributes)
                    .draw(at: CGPoint(x: (landscape.width - width) / 2, y: margin))
                context.endPDFPage()
            }

            func startPage() {
                if !measuring {
                    if pageless {
                        var box = pageRect
                        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
                        context.beginPDFPage(info as CFDictionary)
                    } else {
                        context.beginPDFPage(nil)
                    }
                }
                pageIndex += 1
                cursorY = contentTop
                if pageIndex == 1 {
                    draw(documentTitle, at: CGPoint(x: margin, y: cursorY), width: pageRect.width - 2 * margin, font: titleFont)
                    cursorY -= 22 * text
                    let fixtureWord = fixtures.count == 1 ? "fixture" : "fixtures"
                    draw("\(fixtures.count) \(fixtureWord)", at: CGPoint(x: margin, y: cursorY), width: pageRect.width - 2 * margin, font: subtitleFont, color: .darkGray)
                    cursorY -= 26 * text
                    // Pageless has no page of its own for the render, so it
                    // sits under the title, the full width of the page.
                    if pageless, let stageImage {
                        let width = pageRect.width - 2 * margin
                        let height = width * stageImage.size.height / max(1, stageImage.size.width)
                        if !measuring {
                            stageImage.draw(in: CGRect(x: margin, y: cursorY - height, width: width, height: height))
                            let caption = "3D view for reference only. Not to scale."
                            let attributes: [NSAttributedString.Key: Any] = [
                                .font: NSFontManager.shared.convert(footerFont, toHaveTrait: .italicFontMask),
                                .foregroundColor: NSColor.darkGray,
                            ]
                            let captionWidth = (caption as NSString).size(withAttributes: attributes).width
                            NSAttributedString(string: caption, attributes: attributes)
                                .draw(at: CGPoint(x: (pageRect.width - captionWidth) / 2, y: cursorY - height - 14))
                        }
                        cursorY -= height + 36
                    }
                }
                drawColumnHeaders()
            }

            func endPage() {
                // One page has no page numbers.
                if !pageless { drawFooter() }
                if !measuring { context.endPDFPage() }
            }

            func ensureSpace(_ needed: CGFloat) {
                if !pageless, cursorY - needed < contentBottom {
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

            if let stageImage, !pageless { drawStagePage(stageImage) }
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
            lowestCursor = cursorY
            return pageIndex
        }
        var lowestCursor: CGFloat = 0

        if pageless {
            // Laid out once on a page tall enough for anything, to find how
            // far down the list goes, then drawn on a page cut to fit.
            pageRect.size.height = 1_000_000
            contentTop = pageRect.height - margin
            _ = run(measuring: true, totalPages: 1)
            let used = contentTop - lowestCursor
            pageRect.size.height = (used + 2 * margin).rounded(.up)
            contentTop = pageRect.height - margin
            _ = run(measuring: false, totalPages: 1)
        } else {
            let totalPages = run(measuring: true, totalPages: 0)
            _ = run(measuring: false, totalPages: totalPages)
        }
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
