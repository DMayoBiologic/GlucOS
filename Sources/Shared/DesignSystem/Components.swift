import SwiftUI

// Generic building blocks. Glucose-specific pieces (TrendDial, TimeInRangeRing, RangeBadge) live
// in Theme.swift and GlucoseStyle.swift and are built from these.
//
// Every component here is written to survive a narrow window: single-line labels truncate rather
// than wrap letter by letter, numbers shrink a little before they truncate, and rows reflow onto
// two lines when they run out of width.

// MARK: - Adaptive row

/// Puts `accessory` beside `main` when there's room for `main` to be at least `minMainWidth`
/// wide, and underneath it, leading-aligned, when there isn't. For banners, headers with
/// controls, and legend rows.
///
///     DSAdaptiveRow(minMainWidth: 220) {
///         Text(message)
///         HStack { buttons }
///     }
struct DSAdaptiveRow: Layout {
    var minMainWidth: CGFloat = 200
    var spacing: CGFloat = DS.Space.md
    var verticalSpacing: CGFloat = DS.Space.sm
    /// Vertical alignment of the accessory when side by side.
    var alignment: VerticalAlignment = .center

    private func isSideBySide(width: CGFloat, subviews: Subviews) -> Bool {
        guard subviews.count > 1 else { return true }
        let accessory = subviews[1].sizeThatFits(.unspecified)
        return width - accessory.width - spacing >= minMainWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let main = subviews.first else { return .zero }
        guard subviews.count > 1 else { return main.sizeThatFits(proposal) }
        let accessory = subviews[1].sizeThatFits(.unspecified)
        guard let width = proposal.width, width.isFinite else {
            let ideal = main.sizeThatFits(.unspecified)
            return CGSize(width: ideal.width + spacing + accessory.width, height: max(ideal.height, accessory.height))
        }
        if isSideBySide(width: width, subviews: subviews) {
            let m = main.sizeThatFits(ProposedViewSize(width: width - accessory.width - spacing, height: nil))
            return CGSize(width: width, height: max(m.height, accessory.height))
        }
        let m = main.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let a = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: m.height + verticalSpacing + a.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let main = subviews.first else { return }
        guard subviews.count > 1 else {
            main.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        let accessory = subviews[1]
        let aSize = accessory.sizeThatFits(.unspecified)
        if isSideBySide(width: bounds.width, subviews: subviews) {
            let mainWidth = bounds.width - aSize.width - spacing
            let m = main.sizeThatFits(ProposedViewSize(width: mainWidth, height: nil))
            main.place(at: CGPoint(x: bounds.minX, y: y(for: m.height, in: bounds)),
                       proposal: ProposedViewSize(width: mainWidth, height: m.height))
            accessory.place(at: CGPoint(x: bounds.maxX - aSize.width, y: y(for: aSize.height, in: bounds)),
                            proposal: ProposedViewSize(aSize))
        } else {
            let m = main.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            main.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: m.height))
            let a = accessory.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            accessory.place(at: CGPoint(x: bounds.minX, y: bounds.minY + m.height + verticalSpacing),
                            proposal: ProposedViewSize(width: min(a.width, bounds.width), height: a.height))
        }
    }

    private func y(for height: CGFloat, in bounds: CGRect) -> CGFloat {
        switch alignment {
        case .top: return bounds.minY
        case .bottom: return bounds.maxY - height
        default: return bounds.midY - height / 2
        }
    }
}

// MARK: - Section header

/// A card or section title with optional symbol, subtitle and trailing content (a caption, a
/// button, a picker). The trailing content drops below the title when the card is narrow.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        DSAdaptiveRow(minMainWidth: 140, spacing: DS.Space.sm, verticalSpacing: DS.Space.xs, alignment: .center) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs + 2) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                    }
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .dsFont(.sectionTitle)
                .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }
}

/// The caption on the right of a `SectionHeader`.
struct SectionHeaderCaption: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

extension SectionHeader where Trailing == SectionHeaderCaption {
    /// A header with an optional caption on the right ("target 3.9–10.0").
    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil, trailing caption: String?) {
        self.init(title, systemImage: systemImage, subtitle: subtitle) { SectionHeaderCaption(text: caption) }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil) {
        self.init(title, systemImage: systemImage, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Status pill

/// A small capsule naming a status ("In range", "Stale", "Sensor ending").
struct StatusPill: View {
    let text: String
    var systemImage: String?
    var tone: Tone = .neutral
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol = systemImage ?? tone.systemImage { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .fontWeight(.semibold)
        .dsFont(.label)
        .lineLimit(1)
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, DS.Space.sm + 1)
        .padding(.vertical, DS.Space.xs - 1)
        .background(tone.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(contrast == .increased ? 0.9 : 0.3),
                                        lineWidth: contrast == .increased ? DS.Stroke.increased : 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stat tile

/// One headline number with its label: "Average 11.1 mmol/L". The value takes the tone's
/// colour (neutral values stay primary), shrinks slightly before truncating, and never wraps.
struct StatTile<Footer: View>: View {
    let title: String
    let value: String
    var unit: String?
    var caption: String?
    var tone: Tone = .neutral
    var large = false
    /// Puts the tile on an inset well. Off when tiles sit in a grid on a card that already
    /// groups them.
    var boxed = false
    var help: String?
    @ViewBuilder var footer: () -> Footer

    init(_ title: String, value: String, unit: String? = nil, caption: String? = nil, tone: Tone = .neutral,
         large: Bool = false, boxed: Bool = false, help: String? = nil,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.value = value
        self.unit = unit
        self.caption = caption
        self.tone = tone
        self.large = large
        self.boxed = boxed
        self.help = help
        self.footer = footer
    }

    private var valueStyle: AnyShapeStyle {
        tone == .neutral ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tone.textColor)
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title)
                .dsFont(.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(value)
                    .dsFont(large ? .metricValueLarge : .metricValue)
                    .foregroundStyle(valueStyle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .layoutPriority(1)
                if let unit {
                    Text(unit)
                        .dsFont(.unit)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let caption {
                Text(caption)
                    .dsFont(.caption)
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.textColor))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if boxed {
                content.dsCard(.inset, padding: DS.Space.sm + 2)
            } else {
                content
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Footer == EmptyView {
    init(_ title: String, value: String, unit: String? = nil, caption: String? = nil, tone: Tone = .neutral,
         large: Bool = false, boxed: Bool = false, help: String? = nil) {
        self.init(title, value: value, unit: unit, caption: caption, tone: tone, large: large, boxed: boxed,
                  help: help) { EmptyView() }
    }
}

// MARK: - Legend item

/// A colour key with its label and value: "● Very high  8h 31m  35%". Stays on one line while it
/// can, then moves the detail and value under the label. Never wraps a word mid-way.
struct LegendItem: View {
    let color: Color
    let label: String
    var value: String?
    var detail: String?
    var emphasised = false

    var body: some View {
        DSAdaptiveRow(minMainWidth: 64, spacing: DS.Space.sm, verticalSpacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.sm - 2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .dsFont(emphasised ? .headline : .callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.sm) {
                if let detail {
                    Text(detail)
                        .dsFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let value {
                    Text(value)
                        .fontWeight(.semibold)
                        .dsFont(.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

/// What a section shows when it has nothing to show: a symbol, what's missing, what to do about
/// it, and optionally the one action that helps.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var tone: Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.dsDensity) private var density

    var body: some View {
        VStack(spacing: density == .compact ? DS.Space.sm : DS.Space.md) {
            ZStack {
                Circle().fill(tone.color.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: density == .compact ? 18 : 24, weight: .semibold))
                    .foregroundStyle(tone == .neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(tone.color))
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: density == .compact ? 40 : 56, height: density == .compact ? 40 : 56)
            .accessibilityHidden(true)

            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .dsFont(density == .compact ? .headline : .sectionTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .dsFont(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(tone == .neutral ? .primary : .tinted(tone)))
                    .padding(.top, DS.Space.xs)
            }
        }
        .padding(density == .compact ? DS.Space.md : DS.Space.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}
