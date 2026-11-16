import UIKit

/// Draws a Logbook export (`LogbookExport.Report`) as an A4 PDF for a clinic visit: the figures,
/// time in range as a bar, the usual day by time of day, then every entry grouped by day. Drawn
/// with UIKit on the phone, in print colours that read the same in light and dark mode and on a
/// black-and-white printer (each band is labelled, not only coloured). Nothing leaves the phone
/// until the person shares the file.
enum LogbookPDF {
    static let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 in points
    static let margin: CGFloat = 40
    static var content: CGRect { page.insetBy(dx: margin, dy: margin) }
    /// Room kept at the bottom of every page for the footer.
    static let footerHeight: CGFloat = 34

    // Print colours, fixed rather than taken from the app's light/dark palette.
    enum Ink {
        static let text = UIColor(white: 0.08, alpha: 1)
        static let secondary = UIColor(white: 0.38, alpha: 1)
        static let rule = UIColor(white: 0.82, alpha: 1)
        static let tile = UIColor(white: 0.955, alpha: 1)
        static let veryLow = UIColor(red: 0.62, green: 0.08, blue: 0.10, alpha: 1)
        static let low = UIColor(red: 0.89, green: 0.25, blue: 0.27, alpha: 1)
        static let inRange = UIColor(red: 0.15, green: 0.58, blue: 0.33, alpha: 1)
        static let high = UIColor(red: 0.96, green: 0.67, blue: 0.20, alpha: 1)
        static let veryHigh = UIColor(red: 0.83, green: 0.42, blue: 0.05, alpha: 1)
        static let pattern = UIColor(red: 0.16, green: 0.33, blue: 0.62, alpha: 1)
    }

    /// The finished PDF.
    static func data(_ report: LogbookExport.Report, calendar: Calendar = .autoupdatingCurrent) -> Data {
        let blocks = self.blocks(report, calendar: calendar)
        let pages = paginate(blocks)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: LogbookExport.fileName(report.period, format: .pdf, calendar: calendar)
                .replacingOccurrences(of: ".pdf", with: ""),
            kCGPDFContextCreator as String: "GlucOS",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { ctx in
            for (i, placed) in pages.enumerated() {
                ctx.beginPage()
                for p in placed { p.block.draw(CGRect(x: content.minX, y: p.y, width: content.width, height: p.block.height)) }
                drawFooter(page: i + 1, of: pages.count)
            }
        }
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

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, mono: Bool = false) -> UIFont {
        mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    static func attributed(_ s: String, _ font: UIFont, _ color: UIColor = Ink.text,
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

    static func drawFooter(page: Int, of count: Int) {
        let y = content.maxY - footerHeight + 10
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setStrokeColor(Ink.rule.cgColor)
        ctx?.setLineWidth(0.5)
        ctx?.move(to: CGPoint(x: content.minX, y: y - 4))
        ctx?.addLine(to: CGPoint(x: content.maxX, y: y - 4))
        ctx?.strokePath()
        let pageLabel = attributed("Page \(page) of \(count)", font(7.5), Ink.secondary, align: .right)
        pageLabel.draw(in: CGRect(x: content.maxX - 70, y: y, width: 70, height: 20))
        attributed(LogbookExport.footnote, font(7.5), Ink.secondary)
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
            out.append(text(attributed(LogbookExport.noReadingsLine, font(10), Ink.secondary), spaceAfter: 14))
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
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.setStrokeColor(Ink.rule.cgColor)
            ctx?.setLineWidth(0.5)
            ctx?.move(to: CGPoint(x: r.minX, y: r.maxY))
            ctx?.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx?.strokePath()
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
                Ink.tile.setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 6).fill()
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
        let bands: [(Double, UIColor, String)] = [
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
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.saveGState()
            UIBezierPath(roundedRect: bar, cornerRadius: 3).addClip()
            for b in bands where b.0 > 0 {
                let w = bar.width * CGFloat(b.0 / total)
                b.1.setFill()
                UIRectFill(CGRect(x: x, y: bar.minY, width: w, height: bar.height))
                x += w
            }
            ctx?.restoreGState()
            let w = r.width / CGFloat(bands.count)
            for (i, b) in bands.enumerated() {
                let cell = CGRect(x: r.minX + CGFloat(i) * w, y: bar.maxY + 5, width: w - 4, height: 24)
                let swatch = CGRect(x: cell.minX, y: cell.minY + 2, width: 7, height: 7)
                b.1.setFill()
                UIBezierPath(roundedRect: swatch, cornerRadius: 1.5).fill()
                attributed(Format.percent(b.0), font(9, .bold, mono: true)).draw(in: CGRect(x: cell.minX + 10, y: cell.minY, width: cell.width - 10, height: 12))
                attributed(b.2, font(7), Ink.secondary).draw(in: CGRect(x: cell.minX + 10, y: cell.minY + 11, width: cell.width - 10, height: 12))
            }
        }
    }

    /// The usual day: target band, 10th–90th and 25th–75th percentile bands, and the middle line.
    static func patternChart(_ p: DayPattern, unit: GlucoseUnit, low: Double, high: Double) -> Block {
        Block(height: 190, spaceAfter: 8) { r in
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let axisW: CGFloat = 28, axisH: CGFloat = 14
            let plot = CGRect(x: r.minX + axisW, y: r.minY + 4, width: r.width - axisW, height: r.height - axisH - 4)
            let f = p.filled
            let lo = min(f.map(\.p10).min() ?? 60, low, 60) - 10
            let hi = max(f.map(\.p90).max() ?? 200, high, 200) + 10
            func x(_ minute: Double) -> CGFloat { plot.minX + plot.width * CGFloat(minute / 1440) }
            func y(_ mgdl: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((mgdl - lo) / (hi - lo)) }

            // Target band and its edges.
            Ink.inRange.withAlphaComponent(0.08).setFill()
            UIRectFill(CGRect(x: plot.minX, y: y(high), width: plot.width, height: y(low) - y(high)))
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
                      _ bottom: KeyPath<DayPattern.Slot, Double>, _ color: UIColor) {
                guard let first = slots.first else { return }
                let path = UIBezierPath()
                path.move(to: CGPoint(x: x(first.midMinute), y: y(first[keyPath: top])))
                for s in slots.dropFirst() { path.addLine(to: CGPoint(x: x(s.midMinute), y: y(s[keyPath: top]))) }
                for s in slots.reversed() { path.addLine(to: CGPoint(x: x(s.midMinute), y: y(s[keyPath: bottom]))) }
                path.close()
                color.setFill()
                path.fill()
            }
            for slots in runs {
                band(slots, \.p90, \.p10, Ink.pattern.withAlphaComponent(0.14))
                band(slots, \.p75, \.p25, Ink.pattern.withAlphaComponent(0.30))
                let line = UIBezierPath()
                for (i, s) in slots.enumerated() {
                    let pt = CGPoint(x: x(s.midMinute), y: y(s.p50))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                line.lineWidth = 1.6
                line.lineJoinStyle = .round
                Ink.pattern.setStroke()
                line.stroke()
            }
            ctx.setStrokeColor(Ink.rule.cgColor)
            ctx.setLineWidth(0.6)
            ctx.stroke(plot)

            // Legend, top right inside the plot.
            let legend: [(UIColor, String)] = [
                (Ink.pattern, DayPatternText.legendMedian),
                (Ink.pattern.withAlphaComponent(0.30), DayPatternText.legendInner),
                (Ink.pattern.withAlphaComponent(0.14), DayPatternText.legendOuter),
            ]
            var lx = plot.maxX - 200
            for (color, label) in legend {
                color.setFill()
                UIRectFill(CGRect(x: lx, y: plot.minY + 5, width: 10, height: 6))
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
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.setStrokeColor(Ink.rule.cgColor)
            ctx?.setLineWidth(0.5)
            ctx?.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx?.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx?.strokePath()
        }
    }

    static func dayHeading(_ day: String, totals: String) -> Block {
        Block(height: 20, spaceAfter: 0, keepWithNext: true) { r in
            Ink.tile.setFill()
            UIRectFill(CGRect(x: r.minX, y: r.minY + 2, width: r.width, height: 16))
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
        let note = row.note.isEmpty ? nil : attributed("Note: \(row.note)", font(8.5).italic, Ink.secondary)
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
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.setStrokeColor(Ink.rule.withAlphaComponent(0.6).cgColor)
            ctx?.setLineWidth(0.3)
            ctx?.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx?.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx?.strokePath()
        }
    }
}

private extension UIFont {
    var italic: UIFont {
        fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}
