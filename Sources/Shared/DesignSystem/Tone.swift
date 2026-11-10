import SwiftUI

// Semantic colour. Components take a `Tone`, never a raw colour, so what something means decides
// how it looks, and a stale reading can't be handed a reassuring green by accident.
//
// Each tone has two colours:
// - `color` for fills, lines, icons and large numbers (3:1 against the background or better);
// - `textColor` for small text, darkened in light mode to reach 4.5:1 (WCAG AA).

enum Tone: Equatable {
    /// No status: ordinary chrome.
    case neutral
    /// GlucOS's own accent, for chrome that isn't a glucose value.
    case brand
    /// Something went fine.
    case success
    /// The numbers may be wrong or old, or something needs attention soon.
    case warning
    /// Alerts or readings have stopped, or a value is dangerous.
    case critical
    /// Context.
    case info
    /// Old data. Always neutral grey, whatever the value was.
    case stale
    /// A glucose range's own hue.
    case glucose(GlucoseRange)
    /// An escape hatch for colours outside the semantic set (log categories, chart series).
    case custom(Color)

    var color: Color {
        switch self {
        case .neutral: return Palette.neutral
        case .brand, .info: return Palette.brand
        case .success: return Palette.mint
        case .warning: return Palette.amber
        case .critical: return Palette.crimson
        case .stale: return Palette.stale
        case .glucose(let r): return r.tint
        case .custom(let c): return c
        }
    }

    var textColor: Color {
        switch self {
        case .neutral: return .secondary
        case .brand, .info: return Palette.brandText
        case .success: return GlucoseRange.inRange.textTint
        case .warning: return GlucoseRange.high.textTint
        case .critical: return GlucoseRange.urgentLow.textTint
        case .stale: return Palette.staleText
        case .glucose(let r): return r.textTint
        case .custom(let c): return c
        }
    }

    /// The default symbol for a status tone.
    var systemImage: String? {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .glucose(let r): return r.systemImage
        case .neutral, .brand, .custom: return nil
        }
    }

    /// Whether this tone says "all is well". Stale never does.
    var isReassuring: Bool {
        switch self {
        case .success, .glucose(.inRange): return true
        default: return false
        }
    }
}

extension GlucoseRange {
    /// The range's tone, or `.stale` when the reading is old.
    func tone(stale: Bool) -> Tone { stale ? .stale : .glucose(self) }

    /// Text-safe version of `tint`: darker in light mode so small labels reach 4.5:1.
    var textTint: Color {
        switch self {
        case .urgentLow: return Palette.crimsonText
        case .low: return Palette.coralText
        case .inRange: return Palette.mintText
        case .high: return Palette.amberText
        case .veryHigh: return Palette.magentaText
        }
    }
}

extension GlucoseSnapshot {
    /// The tone the current reading should be shown in: `.stale` when old or missing.
    func displayTone(at now: Date = Date()) -> Tone {
        guard current != nil, let range, !isStale(at: now) else { return .stale }
        return .glucose(range)
    }
}

extension BannerSeverity {
    var tone: Tone {
        switch self {
        case .critical: return .critical
        case .warning: return .warning
        case .info: return .info
        case .success: return .success
        }
    }
}
