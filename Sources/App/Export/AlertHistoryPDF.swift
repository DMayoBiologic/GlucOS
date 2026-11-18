#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws an Alert History export (`AlertHistoryExport.Report`) as an A4 PDF for a clinic visit: the
/// days, the chips it was made under, how the alerts ended, then every alert by day with its time,
/// reading, outcome and note. Built from the Logbook export's pages (`LogbookPDF`: the same print
/// colours, block layout, paginator, day headings and footer), so the two files look like one set.
/// One file for the iPhone and the Mac.
enum AlertHistoryPDF {
    typealias Block = LogbookPDF.Block
    typealias Ink = LogbookPDF.Ink

    static func data(_ report: AlertHistoryExport.Report, calendar: Calendar = .autoupdatingCurrent) -> Data {
        LogbookPDF.render(blocks(report, calendar: calendar),
                          title: AlertHistoryExport.fileName(report, format: .pdf, calendar: calendar)
                              .replacingOccurrences(of: ".pdf", with: ""),
                          footnote: AlertHistoryExport.footnote(report.device))
    }

    static func blocks(_ r: AlertHistoryExport.Report, calendar: Calendar) -> [Block] {
        typealias P = LogbookPDF
        var out: [Block] = []
        let made = LogbookExport.dateFormatter("d MMM yyyy, h:mm a", calendar: calendar).string(from: r.made)

        out.append(P.text(P.attributed("GlucOS Alert History", P.font(20, .bold)), spaceAfter: 2))
        out.append(P.text(P.attributed(LogbookExport.periodLine(r.period, calendar: calendar), P.font(12, .semibold)), spaceAfter: 2))
        out.append(P.text(P.attributed(AlertHistoryExport.showingLine(r), P.font(10, .medium)), spaceAfter: 2))
        out.append(P.text(P.attributed("Glucose in \(r.unit.label) · Made \(made)", P.font(9), Ink.secondary), spaceAfter: 16))

        out.append(P.heading("What happened"))
        if let line = AlertHistoryExport.outcomeLine(r) {
            out.append(P.text(P.attributed(line, P.font(10)), spaceAfter: 16))
        } else {
            out.append(P.text(P.attributed(AlertHistoryExport.emptyLine(r.pick), P.font(10), Ink.secondary), spaceAfter: 16))
            return out
        }

        out.append(P.heading("Alerts"))
        out.append(tableHeader(unit: r.unit))
        let dayFormat = LogbookExport.dateFormatter("EEEE d MMMM", calendar: calendar)
        let timeFormat = LogbookExport.dateFormatter("h:mm a", calendar: calendar)
        for day in AlertHistoryExport.days(r.rows, calendar: calendar) {
            out.append(P.dayHeading(dayFormat.string(from: day.day), totals: AlertHistoryText.count(day.rows.count)))
            for row in day.rows {
                out.append(tableRow(row, unit: r.unit, time: timeFormat, calendar: calendar))
            }
        }
        return out
    }

    // MARK: Table

    /// Column x offsets and widths: time, alert, glucose, what happened (with the note under it).
    static let columns: [(x: CGFloat, w: CGFloat)] = {
        let total = LogbookPDF.content.width
        let time: CGFloat = 52, alert: CGFloat = 150, glucose: CGFloat = 64
        let outcome = total - time - alert - glucose
        return [(0, time), (time, alert), (time + alert, glucose - 10), (time + alert + glucose, outcome)]
    }()

    static func tableHeader(unit: GlucoseUnit) -> Block {
        let titles = ["Time", "Alert", unit.label, "What happened"]
        return Block(height: 16, spaceAfter: 2, keepWithNext: true) { r in
            for (i, t) in titles.enumerated() {
                let c = columns[i]
                LogbookPDF.attributed(t, LogbookPDF.font(8, .semibold), Ink.secondary, align: i == 2 ? .right : .left)
                    .draw(in: CGRect(x: r.minX + c.x, y: r.minY + 2, width: c.w, height: 12))
            }
            LogbookPDF.line(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY), Ink.rule, width: 0.5)
        }
    }

    /// The colour of the alert's dot: the range it was about. Labelled by the alert's name too, so
    /// it reads in black and white.
    static func ink(_ kind: AlertNotice.Kind) -> PlatformColor {
        switch kind {
        case .urgentLow, .predictedUrgentLow: return Ink.veryLow
        case .low, .predictedLow: return Ink.low
        case .veryHigh, .predictedVeryHigh: return Ink.veryHigh
        default: return Ink.high
        }
    }

    static func tableRow(_ row: AlertHistoryExport.Row, unit: GlucoseUnit, time: DateFormatter,
                         calendar: Calendar) -> Block {
        typealias P = LogbookPDF
        let item = row.item
        let alertW = columns[1].w - 14
        let outcomeW = columns[3].w
        let title = P.attributed(item.title, P.font(9, .semibold))
        var outcomeText = item.outcome.text
        if let at = item.respondedAt {
            outcomeText += " at \(time.string(from: at))"
            if !calendar.isDate(at, inSameDayAs: item.firedAt) {
                outcomeText += LogbookExport.dateFormatter(" (d MMM)", calendar: calendar).string(from: at)
            }
        }
        let outcome = P.attributed(outcomeText, P.font(9))
        let note = row.note.isEmpty ? nil : P.attributed("Note: \(row.note)", P.font(8.5).pdfItalic, Ink.secondary)
        let reading = item.readingMgdl.map { P.attributed(unit.format(mgdl: $0), P.font(9, .semibold, mono: true), align: .right) }
            ?? P.attributed("No reading", P.font(8.5), Ink.secondary, align: .right)
        let titleH = P.height(title, width: alertW)
        let outcomeH = P.height(outcome, width: outcomeW)
        let noteH = note.map { P.height($0, width: outcomeW) } ?? 0
        let h = max(14, titleH, outcomeH + noteH + (noteH > 0 ? 1 : 0)) + 6
        return Block(height: h) { r in
            let y = r.minY + 3
            P.attributed(time.string(from: item.firedAt), P.font(9, mono: true))
                .draw(in: CGRect(x: r.minX + columns[0].x, y: y, width: columns[0].w, height: 12))
            P.fill(CGRect(x: r.minX + columns[1].x, y: y + 3, width: 6, height: 6), ink(item.kind), radius: 3)
            title.draw(with: CGRect(x: r.minX + columns[1].x + 12, y: y, width: alertW, height: titleH),
                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            reading.draw(in: CGRect(x: r.minX + columns[2].x, y: y, width: columns[2].w, height: 12))
            outcome.draw(with: CGRect(x: r.minX + columns[3].x, y: y, width: outcomeW, height: outcomeH),
                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            note?.draw(with: CGRect(x: r.minX + columns[3].x, y: y + outcomeH + 1, width: outcomeW, height: noteH),
                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            P.line(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY),
                   Ink.rule.withAlphaComponent(0.6), width: 0.3)
        }
    }
}
