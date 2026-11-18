import SwiftUI

/// What's New (docs/WhatsNew.md): a release's highlights, each row rising in once as the sheet
/// opens (instant under Reduce Motion), and a Done button. A sheet on iPhone; a card over the menu
/// bar popover, or a sheet in Settings, on the Mac. The rules live in `WhatsNew` (Engine).
struct WhatsNewView: View {
    let releases: [WhatsNewRelease]
    /// Tighter padding, for the menu bar popover.
    var compact = false
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flips once when the view appears; every row animates off it with its own delay.
    @State private var risen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? DS.Space.lg : DS.Space.xl) {
                    header
                    ForEach(sections) { section in
                        releaseSection(section)
                    }
                }
                .padding(compact ? DS.Space.lg : DS.Space.xxl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            doneButton
        }
        .onAppear { risen = true }
        #if os(macOS)
        .frame(minWidth: compact ? nil : 420, minHeight: compact ? nil : 360)
        // Esc closes it like Done: the card over the popover, or the sheet in Settings.
        .closesOnEscape(onDone)
        #endif
    }

    /// Each release with the index of its first row, so the rise staggers across releases.
    private var sections: [WhatsNewSection] {
        var next = 0
        return releases.map { release in
            defer { next += release.highlights.count }
            return WhatsNewSection(release: release, firstRow: next)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 26 : 34, weight: .semibold))
                .foregroundStyle(Palette.brandGradient)
                .accessibilityHidden(true)
            Text(WhatsNew.title(for: releases))
                .dsFont(.title)
                .accessibilityAddTraits(.isHeader)
            Text("GlucOS updated itself. Here's what changed.")
                .dsFont(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func releaseSection(_ section: WhatsNewSection) -> some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.md : DS.Space.lg) {
            if releases.count > 1 {
                Text("Version \(section.release.shortVersion)")
                    .dsFont(.eyebrow)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(section.release.highlights.indices, id: \.self) { offset in
                row(section.release.highlights[offset])
                    .modifier(WhatsNewRise(shown: risen, reduceMotion: reduceMotion,
                                           delay: WhatsNew.riseDelay(row: section.firstRow + offset,
                                                                     reduceMotion: reduceMotion)))
            }
        }
    }

    private func row(_ highlight: WhatsNewHighlight) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: highlight.symbol)
                .font(.system(size: compact ? 18 : 22, weight: .semibold))
                .foregroundStyle(Palette.brandGradient)
                .frame(width: compact ? 26 : 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(highlight.title).dsFont(.headline)
                Text(highlight.detail)
                    .dsFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var doneButton: some View {
        HStack {
            #if os(macOS)
            Spacer()
            #endif
            Button(action: onDone) {
                Text("Done")
                    #if os(iOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .buttonStyle(.ds(.primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, compact ? DS.Space.lg : DS.Space.xxl)
        .padding(.vertical, compact ? DS.Space.md : DS.Space.lg)
    }
}

/// One release in the sheet, with the index of its first row across the whole sheet.
private struct WhatsNewSection: Identifiable {
    let release: WhatsNewRelease
    let firstRow: Int
    var id: String { release.id }
}

/// A row's one-time rise: up from `WhatsNew.riseDistance` below while fading in, after its
/// stagger delay. Under Reduce Motion the row is simply there.
private struct WhatsNewRise: ViewModifier {
    let shown: Bool
    let reduceMotion: Bool
    let delay: TimeInterval

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : WhatsNew.riseDistance)
            .animation(reduceMotion ? nil : .easeOut(duration: WhatsNew.riseDuration).delay(delay), value: shown)
    }
}

/// The app's version, as What's New compares it.
enum WhatsNewVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Settings › About's "What's New" row: opens every release's highlights up to this version.
/// The caller attaches `.settingsAnchor(.whatsNew)` to the row it sits in.
struct WhatsNewSettingsRow: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            #if os(iOS)
            Label("What's New", systemImage: "sparkles")
            #else
            Text("What's New…")
            #endif
        }
        .sheet(isPresented: $showing) {
            WhatsNewView(releases: WhatsNew.all(current: WhatsNewVersion.current)) { showing = false }
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }
}
