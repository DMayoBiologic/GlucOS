import Foundation

/// Short labels beside logged markers ("45 g", "4 u") on iPhone Today and the Mac popover, shown
/// only once the chart is zoomed in far enough for them to have room. Each label sits just after
/// its marker (before it, when that would run past the right edge), and a label that would cover
/// another label or another marker is left out: the higher-priority one stays (insulin, then food),
/// and between equals the newer one. They fade in and out as the hours change; under Reduce Motion
/// they just appear and go. VoiceOver is unchanged: each marker already says what it was.
///
/// Plain Foundation so it can be unit-tested; `MarkerLabelLayer` in GlucoseChart draws them, and
/// `ChartLogMarker.logbook` gives each marker its text. Labels only repeat what was logged.
enum MarkerLabels {
    /// Labels show once the time axis gives each hour at least this many points: 3 h and 6 h on
    /// iPhone, 3 h in the Mac popover. Wider spans hide them all.
    static let minPointsPerHour: Double = 50
    /// The marker's drawn size (`EventSymbol`), which another marker's label must keep clear of.
    static let markerSize: Double = 16
    /// Between the marker's edge and its label.
    static let gap: Double = 2
    /// The label's height, and its width per character and padding (an estimate of the 9 pt
    /// semibold caption it's drawn in, a little generous so near misses count as overlaps).
    static let height: Double = 12
    static let charWidth: Double = 5.6
    static let padding: Double = 6
    /// How long the fade takes, and how long a label coming in waits for the axes to settle.
    static let fadeDuration: Double = 0.22
    static let fadeInDelay: Double = 0.12

    /// A marker that could have a label, in the plot's own points.
    struct Candidate: Equatable {
        let id: UUID
        let x: Double
        let y: Double
        let text: String
        let priority: Int
        let date: Date
    }

    /// Where one label is drawn: its centre, and the rectangle it covers.
    struct Placement: Equatable {
        let id: UUID
        let centerX: Double
        let centerY: Double
        let width: Double
        /// Whether it sits before its marker (it would have run past the right edge).
        let leading: Bool

        var minX: Double { centerX - width / 2 }
        var maxX: Double { centerX + width / 2 }
        var minY: Double { centerY - MarkerLabels.height / 2 }
        var maxY: Double { centerY + MarkerLabels.height / 2 }
    }

    /// Whether the chart is zoomed in far enough for labels at all.
    static func zoomedIn(plotWidth: Double, hours: Double) -> Bool {
        guard plotWidth > 0, hours > 0 else { return false }
        return plotWidth / hours >= minPointsPerHour
    }

    /// Which markers get a label: insulin first, then food. Wake-ups, notes and sensor starts have
    /// no amount, so no label.
    static func priority(_ kind: MarkerPop.Kind?) -> Int? {
        guard let kind else { return nil }
        switch kind {
        case .insulin: return 2
        case .meal, .treatment: return 1
        case .wake, .note, .sensor: return nil
        }
    }

    static func width(_ text: String) -> Double {
        Double(text.count) * charWidth + padding
    }

    /// Where `c`'s label goes in a plot `plotWidth` wide: after the marker, or before it when
    /// that would run past the right edge. Nil when it fits on neither side.
    static func placement(_ c: Candidate, plotWidth: Double) -> Placement? {
        let w = width(c.text)
        let offset = markerSize / 2 + gap + w / 2
        if c.x + offset + w / 2 <= plotWidth {
            return Placement(id: c.id, centerX: c.x + offset, centerY: c.y, width: w, leading: false)
        }
        if c.x - offset - w / 2 >= 0 {
            return Placement(id: c.id, centerX: c.x - offset, centerY: c.y, width: w, leading: true)
        }
        return nil
    }

    /// Where each label would be drawn, shown or not, so one fading out stays beside its marker.
    static func placements(_ candidates: [Candidate], plotWidth: Double) -> [UUID: Placement] {
        var out: [UUID: Placement] = [:]
        for c in candidates { out[c.id] = placement(c, plotWidth: plotWidth) }
        return out
    }

    /// The labels that are shown: none unless zoomed in, then the highest-priority (then newest)
    /// first, each kept only if it covers no label already kept and no other marker. `obstacles`
    /// are every marker on screen, labelled or not.
    static func shown(_ candidates: [Candidate], obstacles: [(x: Double, y: Double)],
                      plotWidth: Double, hours: Double) -> Set<UUID> {
        guard zoomedIn(plotWidth: plotWidth, hours: hours) else { return [] }
        let ordered = candidates.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.date > $1.date
        }
        var kept: [Placement] = []
        for c in ordered {
            guard let p = placement(c, plotWidth: plotWidth) else { continue }
            if kept.contains(where: { overlaps(p, $0) }) { continue }
            // Its own marker is beside it, never under it; any other marker it touches wins.
            let half = markerSize / 2
            let coversMarker = obstacles.contains { o in
                !(o.x == c.x && o.y == c.y)
                    && o.x + half > p.minX && o.x - half < p.maxX
                    && o.y + half > p.minY && o.y - half < p.maxY
            }
            if coversMarker { continue }
            kept.append(p)
        }
        return Set(kept.map(\.id))
    }

    static func overlaps(_ a: Placement, _ b: Placement) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }
}
