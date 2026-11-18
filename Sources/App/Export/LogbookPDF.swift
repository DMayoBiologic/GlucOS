#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws a Logbook export (`LogbookExport.Report`) as an A4 PDF for a clinic visit: the figures,
/// time in range as a bar, the usual day by time of day, then every entry grouped by day. One file
/// for the iPhone (UIGraphicsPDFRenderer) and the Mac (a Core Graphics PDF context with a flipped
/// AppKit context on top), so both print the same sheet. Everything is drawn through Core Graphics
/// and attributed-string drawing, which behave the same on both once the page is top-left origin.
/// Print colours read the same in light and dark mode and on a black-and-white printer (each band
/// is labelled, not only coloured). Nothing leaves the device until the person shares the file.
enum LogbookPDF {
    #if os(macOS)
    typealias PDFFont = NSFont
    #else
    typealias PDFFont = UIFont
    #endif

    static let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 in points
    static let margin: CGFloat = 40
    static var content: CGRect { page.insetBy(dx: margin, dy: margin) }
    /// Room kept at the bottom of every page for the footer.
    static let footerHeight: CGFloat = 34

    // Print colours, fixed rather than taken from the app's light/dark palette.
    // sRGB on both platforms, so the Mac's PDF matches the iPhone's colour for colour.
    enum Ink {
        static let text = gray(0.08)
        static let secondary = gray(0.38)
        static let rule = gray(0.82)
        static let tile = gray(0.955)
        static let veryLow = rgb(0.62, 0.08, 0.10)
        static let low = rgb(0.89, 0.25, 0.27)
        static let inRange = rgb(0.15, 0.58, 0.33)
        static let high = rgb(0.96, 0.67, 0.20)
        static let veryHigh = rgb(0.83, 0.42, 0.05)
        static let pattern = rgb(0.16, 0.33, 0.62)

        static func gray(_ w: CGFloat) -> PlatformColor { rgb(w, w, w) }
        static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
            #if os(macOS)
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            #else
            UIColor(red: r, green: g, blue: b, alpha: 1)
            #endif
        }
    }

    /// The finished PDF.
    static func data(_ report: LogbookExport.Report, calendar: Calendar = .autoupdatingCurrent) -> Data {
        render(blocks(report, calendar: calendar),
               title: LogbookExport.fileName(report.period, format: .pdf, calendar: calendar)
                   .replacingOccurrences(of: ".pdf", with: ""),
               footnote: LogbookExport.footnote(report.device))
    }

    /// Lays `blocks` out on A4 pages, each with the footer, and returns the PDF. Shared by the
    /// Logbook export and the Alert History export (`AlertHistoryPDF`).
    static func render(_ blocks: [Block], title: String, footnote: String) -> Data {
        let pages = paginate(blocks)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "GlucOS",
        ]
        func drawPage(_ i: Int) {
            for p in pages[i] { p.block.draw(CGRect(x: content.minX, y: p.y, width: content.width, height: p.block.height)) }
            drawFooter(page: i + 1, of: pages.count, footnote: footnote)
        }
        #if os(macOS)
        let out = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        let previous = NSGraphicsContext.current
        for i in pages.indices {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Top-left origin like UIKit's renderer, so every block draws the same on both.
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            drawPage(i)
            NSGraphicsContext.current = previous
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
        #else
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { ctx in
            for i in pages.indices {
                ctx.beginPage()
                drawPage(i)
            }
        }
        #endif
    }

    // MARK: Drawing (both platforms)

    /// The page being drawn: UIKit's renderer context, or the flipped AppKit context set above.
    static var cg: CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }

    static func fill(_ rect: CGRect, _ color: PlatformColor, radius: CGFloat = 0) {
        guard let ctx = cg else { return }
        ctx.setFillColor(color.cgColor)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    static func line(from a: CGPoint, to b: CGPoint, _ color: PlatformColor, width: CGFloat) {
        guard let ctx = cg else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    // MARK: Layout

    /// A piece of the page with a fixed height. `keepWithNext` holds a heading on the same page as
    /// what follows it.
    struct Block {
        var height: CGFloat
        var spaceAfter: CGFloat = 0
        var keepWithNext = false
        var startsPage = false
        var draw: (CGRect) -> Void
    }

    struct Placed {
        var block: Block
        var y: CGFloat
    }

    static func paginate(_ blocks: [Block]) -> [[Placed]] {
        let top = content.minY
        let bottom = content.maxY - footerHeight
        var pages: [[Placed]] = [[]]
        var y = top
        var i = 0
        while i < blocks.count {
            let b = blocks[i]
            var needed = b.height
            if b.keepWithNext, i + 1 < blocks.count { needed += b.spaceAfter + blocks[i + 1].height }
            let pageEmpty = pages[pages.count - 1].isEmpty
            if !pageEmpty && (b.startsPage || y + needed > bottom) {
                pages.append([])
                y = top
            }
            pages[pages.count - 1].append(Placed(block: b, y: y))
            y += b.height + b.spaceAfter
            i += 1
        }
        return pages
    }

    // MARK: Text

    static func font(_ size: CGFloat, _ weight: PDFFont.Weight = .regular, mono: Bool = false) -> PDFFont {
        mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    static func attributed(_ s: String, _ font: PDFFont, _ color: PlatformColor = Ink.text,
                           align: NSTextAlignment = .left) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    static func height(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(a.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    static func text(_ a: NSAttributedString, spaceAfter: CGFloat = 6, keepWithNext: Bool = false,
                     startsPage: Bool = false) -> Block {
        let h = height(a, width: content.width)
        return Block(height: h, spaceAfter: spaceAfter, keepWithNext: keepWithNext, startsPage: startsPage) { r in
            a.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    static func drawFooter(page: Int, of count: Int, footnote: String) {
        let y = content.maxY - footerHeight + 10
        line(from: CGPoint(x: content.minX, y: y - 4), to: CGPoint(x: content.maxX, y: y - 4), Ink.rule, width: 0.5)
        let pageLabel = attributed("Page \(page) of \(count)", font(7.5), Ink.secondary, align: .right)
        pageLabel.draw(in: CGRect(x: content.maxX - 70, y: y, width: 70, height: 20))
        attributed(footnote, font(7.5), Ink.secondary)
            .draw(with: CGRect(x: content.minX, y: y, width: content.width - 80, height: 24),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: Blocks

    static func blocks(_ r: LogbookExport.Report, calendar: Calendar) -> [Block] {
        var out: [Block] = []
        let unit = r.unit
        let made = LogbookExport.dateFormatter("d MMM yyyy, h:mm a", calendar: calendar).string(from: r.made)

        out.append(text(attributed("GlucOS Logbook summary", font(20, .bold)), spaceAfter: 2))
        out.append(text(attributed(LogbookExport.periodLine(r.period, calendar: calendar), font(12, .semibold)), spaceAfter: 2))
        out.append(text(attributed("Target \(unit.format(mgdl: r.lowMgdl))–\(unit.format(mgdl: r.highMgdl)) \(unit.label) · Made \(made)",
                                   font(9), Ink.secondary), spaceAfter: 16))

        out.append(heading("Glucose"))
        if let s = r.summary {
            out.append(tiles(s, unit: unit, low: r.lowMgdl, high: r.highMgdl, period: r.period))
            out.append(rangeBar(s, unit: unit, low: r.lowMgdl, high: r.highMgdl))
        } else {
            out.append(text(attributed(LogbookExport.noReadingsLine(r.device), font(10), Ink.secondary), spaceAfter: 14))
        }

        out.append(heading("Logged"))
        for line in LogbookExport.loggedLines(r.totals, days: r.period.days) {
            out.append(text(attributed(line, font(10)), spaceAfter: 3))
        }
        out[out.count - 1].spaceAfter = 16

        out.append(heading(DayPatternText.title))
        if let p = r.pattern {
            out.append(patternChart(p, unit: unit, low: r.lowMgdl, high: r.highMgdl))
            for line in DayPatternText.lines(p, unit: unit, low: r.lowMgdl, high: r.highMgdl) {
                out.append(text(attributed(line, font(10)), spaceAfter: 3))
            }
            out.append(text(attributed(DayPatternText.footnote, font(8), Ink.secondary), spaceAfter: 16))
        } else {
            out.append(text(attributed("Shown once there are \(DayPattern.minimumDays) days of readings in the period.",
                                       font(10), Ink.secondary), spaceAfter: 16))
        }

        // The entries start on a page of their own, so the summary prints as one sheet.
        let entriesTitle = r.rows.isEmpty ? "Entries" : "Entries (\(r.rows.count))"
        out.append(text(attributed(entriesTitle, font(14, .bold)), spaceAfter: 8, keepWithNext: true, startsPage: true))
        if r.rows.isEmpty {
            out.append(text(attributed("Nothing was logged in these days.", font(10), Ink.secondary)))
        } else {
            out.append(tableHeader())
            let dayFormat = LogbookExport.dateFormatter("EEEE d MMMM", calendar: calendar)
            let timeFormat = LogbookExport.dateFormatter("h:mm a", calendar: calendar)
            for day in LogbookExport.days(r.rows, calendar: calendar) {
                out.append(dayHeading(dayFormat.string(from: day.day), totals: LogbookExport.dayTotals(day.rows)))
                for row in day.rows { out.append(tableRow(row, time: timeFormat.string(from: row.timestamp))) }
            }
        }
        return out
    }

    static func heading(_ title: String) -> Block {
        let a = attributed(title.uppercased(), font(9, .bold), Ink.secondary)
        let h = height(a, width: content.width)
        return Block(height: h + 5, spaceAfter: 6, keepWithNext: true) { r in
            a.draw(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
            line(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY), Ink.rule, width: 0.5)
        }
    }

    /// Two rows of four figures.
    static func tiles(_ s: LogbookExport.Summary, unit: GlucoseUnit, low: Double, high: Double,
                      period: LogbookExport.Period) -> Block {
        let pct = { (v: Double) in Format.percent(v) }
        let items: [(String, String, String)] = [
            ("Time in range", pct(s.timeInRange), "\(unit.format(mgdl: low))–\(unit.format(mgdl: high)) \(unit.label)"),
            ("Average", unit.format(mgdl: s.meanMgdl), unit.label),
            ("Lows", LogbookExport.lowsValue(s.lows), "15 min or longer"),
            ("GMI", String(format: "%.1f%%", s.gmiPercent), String(format: "%.0f mmol/mol", s.gmiMmolPerMol)),
            ("Below range", pct(s.below), "Very low \(pct(s.veryLow))"),
            ("Above range", pct(s.above), "Very high \(pct(s.veryHigh))"),
            ("Variability (CV)", pct(s.coefficientOfVariation), "SD \(unit.format(mgdl: s.sdMgdl))"),
            ("Sensor data", pct(s.coverage), "\(s.daysWithReadings) of \(period.days) days"),
        ]
        let gap: CGFloat = 8
        let tileH: CGFloat = 54
        return Block(height: tileH * 2 + gap, spaceAfter: 12) { r in
            let w = (r.width - gap * 3) / 4
            for (i, item) in items.enumerated() {
                let col = CGFloat(i % 4), row = CGFloat(i / 4)
                let box = CGRect(x: r.minX + col * (w + gap), y: r.minY + row * (tileH + gap), width: w, height: tileH)
                fill(box, Ink.tile, radius: 6)
                let inner = box.insetBy(dx: 8, dy: 6)
                attributed(item.0, font(8, .semibold), Ink.secondary).draw(in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 11))
                attributed(item.1, font(17, .bold, mono: true)).draw(in: CGRect(x: inner.minX, y: inner.minY + 11, width: inner.width, height: 22))
                attributed(item.2, font(7.5), Ink.secondary).draw(in: CGRect(x: inner.minX, y: inner.minY + 32, width: inner.width, height: 11))
            }
        }
    }

    /// Time in each band as one bar, very low to very high, with each band's share labelled under it.
    static func rangeBar(_ s: LogbookExport.Summary, unit: GlucoseUnit, low: Double, high: Double) -> Block {
        let veryLow = unit.format(mgdl: LogbookExport.veryLowMgdl), veryHigh = unit.format(mgdl: LogbookExport.veryHighMgdl)
        let lo = unit.format(mgdl: low), hi = unit.format(mgdl: high)
        let bands: [(Double, PlatformColor, String)] = [
            (s.veryLow, Ink.veryLow, "Very low (<\(veryLow))"),
            (max(0, s.below - s.veryLow), Ink.low, "Low (\(veryLow)–\(lo))"),
            (s.timeInRange, Ink.inRange, "In range (\(lo)–\(hi))"),
            (max(0, s.above - s.veryHigh), Ink.high, "High (\(hi)–\(veryHigh))"),
            (s.veryHigh, Ink.veryHigh, "Very high (>\(veryHigh))"),
        ]
        return Block(height: 42, spaceAfter: 16) { r in
            let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 14)
            var x = bar.minX
            let total = max(0.0001, bands.reduce(0) { $0 + $1.0 })
            let ctx = cg
            ctx?.saveGState()
            ctx?.addPath(CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx?.clip()
            for b in bands where b.0 > 0 {
                let w = bar.width * CGFloat(b.0 / total)
                fill(CGRect(x: x, y: bar.minY, width: w, height: bar.height), b.1)
                x += w
            }
            ctx?.restoreGState()
            let w = r.width / CGFloat(bands.count)
            for (i, b) in bands.enumerated() {
                let cell = CGRect(x: r.minX + CGFloat(i) * w, y: bar.maxY + 5, width: w - 4, height: 24)
                let swatch = CGRect(x: cell.minX, y: cell.minY + 2, width: 7, height: 7)
                fill(swatch, b.1, radius: 1.5)
                attributed(Format.percent(b.0), font(9, .bold, mono: true)).draw(in: CGRect(x: cell.minX + 10, y: cell.minY, width: cell.width - 10, height: 12))
                attributed(b.2, font(7), Ink.secondary).draw(in: CGRect(x: cell.minX + 10, y: cell.minY + 11, width: cell.width - 10, height: 12))
            }
        }
    }

    /// The usual day: target band, 10th–90th and 25th–75th percentile bands, and the middle line.
    static func patternChart(_ p: DayPattern, unit: GlucoseUnit, low: Double, high: Double) -> Block {
        Block(height: 190, spaceAfter: 8) { r in
            guard let ctx = cg else { return }
            let axisW: CGFloat = 28, axisH: CGFloat = 14
            let plot = CGRect(x: r.minX + axisW, y: r.minY + 4, width: r.width - axisW, height: r.height - axisH - 4)
            let f = p.filled
            let lo = min(f.map(\.p10).min() ?? 60, low, 60) - 10
            let hi = max(f.map(\.p90).max() ?? 200, high, 200) + 10
            func x(_ minute: Double) -> CGFloat { plot.minX + plot.width * CGFloat(minute / 1440) }
            func y(_ mgdl: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((mgdl - lo) / (hi - lo)) }

            // Target band and its edges.
            fill(CGRect(x: plot.minX, y: y(high), width: plot.width, height: y(low) - y(high)), Ink.inRange.withAlphaComponent(0.08))
            ctx.setStrokeColor(Ink.inRange.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(0.6)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            for v in [low, high] {
                ctx.move(to: CGPoint(x: plot.minX, y: y(v))); ctx.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // Hour grid and labels, every 3 hours.
            ctx.setStrokeColor(Ink.rule.cgColor)
            ctx.setLineWidth(0.4)
            for h in stride(from: 0, through: 24, by: 3) {
                let gx = x(Double(h * 60))
                ctx.move(to: CGPoint(x: gx, y: plot.minY)); ctx.addLine(to: CGPoint(x: gx, y: plot.maxY))
                if h < 24 {
                    let label = h == 0 ? "12 am" : (h == 12 ? "12 pm" : DayPatternText.clock(h * 60))
                    attributed(label, font(7), Ink.secondary).draw(at: CGPoint(x: gx + 2, y: plot.maxY + 2))
                }
            }
            ctx.strokePath()
            // Value labels at the target edges and the very low/high cut-offs inside the domain.
            for v in [low, high, LogbookExport.veryLowMgdl, LogbookExport.veryHighMgdl] where v > lo && v < hi {
                let a = attributed(unit.format(mgdl: v), font(7, mono: true), Ink.secondary, align: .right)
                a.draw(in: CGRect(x: r.minX, y: y(v) - 5, width: axisW - 4, height: 10))
            }

            // Runs of filled slots, so a gap in the data is a gap in the chart.
            var runs: [[DayPattern.Slot]] = []
            var run: [DayPattern.Slot] = []
            for s in p.slots {
                if let s { run.append(s) } else if !run.isEmpty { runs.append(run); run = [] }
            }
            if !run.isEmpty { runs.append(run) }

            func band(_ slots: [DayPattern.Slot], _ top: KeyPath<DayPattern.Slot, Double>,
                      _ bottom: KeyPath<DayPattern.Slot, Double>, _ color: PlatformColor) {
                guard let first = slots.first else { return }
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x(first.midMinute), y: y(first[keyPath: top])))
                for s in slots.dropFirst() { path.addLine(to: CGPoint(x: x(s.midMinute), y: y(s[keyPath: top]))) }
                for s in slots.reversed() { path.addLine(to: CGPoint(x: x(s.midMinute), y: y(s[keyPath: bottom]))) }
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            for slots in runs {
                band(slots, \.p90, \.p10, Ink.pattern.withAlphaComponent(0.14))
                band(slots, \.p75, \.p25, Ink.pattern.withAlphaComponent(0.30))
                let median = CGMutablePath()
                for (i, s) in slots.enumerated() {
                    let pt = CGPoint(x: x(s.midMinute), y: y(s.p50))
                    if i == 0 { median.move(to: pt) } else { median.addLine(to: pt) }
                }
                ctx.addPath(median)
                ctx.setLineWidth(1.6)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(Ink.pattern.cgColor)
                ctx.strokePath()
            }
            ctx.setStrokeColor(Ink.rule.cgColor)
            ctx.setLineWidth(0.6)
            ctx.stroke(plot)

            // Legend, top right inside the plot.
            let legend: [(PlatformColor, String)] = [
                (Ink.pattern, DayPatternText.legendMedian),
                (Ink.pattern.withAlphaComponent(0.30), DayPatternText.legendInner),
                (Ink.pattern.withAlphaComponent(0.14), DayPatternText.legendOuter),
            ]
            var lx = plot.maxX - 200
            for (color, label) in legend {
                fill(CGRect(x: lx, y: plot.minY + 5, width: 10, height: 6), color)
                let a = attributed(label, font(7), Ink.secondary)
                a.draw(at: CGPoint(x: lx + 13, y: plot.minY + 2))
                lx += 13 + a.size().width + 10
            }
        }
    }

    // MARK: Table

    /// Column x offsets and widths: time, type, details (with site and note), insulin, carbs.
    static let columns: [(x: CGFloat, w: CGFloat)] = {
        let total = content.width
        let time: CGFloat = 52, type: CGFloat = 78, units: CGFloat = 50, carbs: CGFloat = 50
        let details = total - time - type - units - carbs
        return [(0, time), (time, type), (time + type, details - 8),
                (time + type + details, units), (time + type + details + units, carbs)]
    }()

    static func tableHeader() -> Block {
        let titles = ["Time", "Type", "Details", "Insulin", "Carbs"]
        return Block(height: 16, spaceAfter: 2, keepWithNext: true) { r in
            for (i, t) in titles.enumerated() {
                let c = columns[i]
                attributed(t, font(8, .semibold), Ink.secondary, align: i >= 3 ? .right : .left)
                    .draw(in: CGRect(x: r.minX + c.x, y: r.minY + 2, width: c.w, height: 12))
            }
            line(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY), Ink.rule, width: 0.5)
        }
    }

    static func dayHeading(_ day: String, totals: String) -> Block {
        Block(height: 20, spaceAfter: 0, keepWithNext: true) { r in
            fill(CGRect(x: r.minX, y: r.minY + 2, width: r.width, height: 16), Ink.tile)
            attributed(day, font(9, .bold)).draw(in: CGRect(x: r.minX + 4, y: r.minY + 4, width: r.width * 0.6, height: 12))
            attributed(totals, font(8.5, .semibold, mono: true), Ink.secondary, align: .right)
                .draw(in: CGRect(x: r.minX + r.width * 0.4, y: r.minY + 4, width: r.width * 0.6 - 4, height: 12))
        }
    }

    static func tableRow(_ row: LogbookExport.Row, time: String) -> Block {
        let detailsW = columns[2].w
        var lines = row.details.isEmpty ? [] : [row.details]
        if !row.insulinType.isEmpty, row.insulinType != row.details { lines.append(row.insulinType) }
        if !row.site.isEmpty { lines.append("Site: \(row.site)") }
        let main = attributed(lines.joined(separator: " · "), font(9))
        let note = row.note.isEmpty ? nil : attributed("Note: \(row.note)", font(8.5).pdfItalic, Ink.secondary)
        let type = attributed(row.type, font(9, .semibold))
        let typeH = height(type, width: columns[1].w - 4)
        let mainH = lines.isEmpty ? 0 : height(main, width: detailsW)
        let noteH = note.map { height($0, width: detailsW) } ?? 0
        let h = max(14, typeH, mainH + noteH + (mainH > 0 && noteH > 0 ? 1 : 0)) + 6
        return Block(height: h) { r in
            let y = r.minY + 3
            attributed(time, font(9, mono: true)).draw(in: CGRect(x: r.minX + columns[0].x, y: y, width: columns[0].w, height: 12))
            type.draw(with: CGRect(x: r.minX + columns[1].x, y: y, width: columns[1].w - 4, height: typeH),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if mainH > 0 {
                main.draw(with: CGRect(x: r.minX + columns[2].x, y: y, width: detailsW, height: mainH),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            note?.draw(with: CGRect(x: r.minX + columns[2].x, y: y + mainH + (mainH > 0 ? 1 : 0), width: detailsW, height: noteH),
                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if let u = row.insulinUnits {
                attributed(LogFormat.units(u), font(9, .semibold, mono: true), align: .right)
                    .draw(in: CGRect(x: r.minX + columns[3].x, y: y, width: columns[3].w, height: 12))
            }
            if let c = row.carbs {
                attributed(LogFormat.grams(c), font(9, .semibold, mono: true), align: .right)
                    .draw(in: CGRect(x: r.minX + columns[4].x, y: y, width: columns[4].w, height: 12))
            }
            line(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY), Ink.rule.withAlphaComponent(0.6), width: 0.3)
        }
    }
}

extension LogbookPDF.PDFFont {
    /// The same font in italic, for notes.
    var pdfItalic: LogbookPDF.PDFFont {
        #if os(macOS)
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(.italic), size: pointSize) ?? self
        #else
        fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: pointSize) } ?? self
        #endif
    }
}
