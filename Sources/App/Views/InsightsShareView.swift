import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Share one Insights card as a picture, on iPhone and Mac (docs/InsightsShare.md). Touch and hold
// (iPhone) or right-click (Mac) a card and pick Share Card…: a sheet shows the picture that will
// leave the device, the card as it is with a small footer naming the card, its period and dates
// (`InsightsShare.footer`), and its Share button opens the system share sheet. The picture holds
// nothing but the card and that footer: no name, email or account.

private struct InsightsShareSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The card is being drawn into a shared picture: leave out controls a picture can't show
    /// (period pickers; the footer says the period instead). Off everywhere else.
    var insightsShareSnapshot: Bool {
        get { self[InsightsShareSnapshotKey.self] }
        set { self[InsightsShareSnapshotKey.self] = newValue }
    }
}

/// What goes into the picture: the card, then the footer, on an opaque backdrop so the card's
/// glass reads the same wherever the picture lands.
struct InsightsShareImage: View {
    let content: AnyView
    let footer: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            content
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(footer)
                    .dsFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(InsightsShare.credit)
                    .dsFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.xs)
        }
        .padding(DS.Space.lg)
        .frame(width: width, alignment: .leading)
        .background(Self.backdrop)
        .environment(\.insightsShareSnapshot, true)
        // Figures and charts show their final values, not a frame of their entrance.
        .environment(\.figuresCountUp, false)
        .transaction { t in
            t.disablesAnimations = true
            t.animation = nil
        }
    }

    private static var backdrop: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// Draws the picture. The renderer is kept alive so a card that works its figures out a moment
/// after it appears (most of them, from their caches) is drawn once it has settled, not blank.
@MainActor
final class InsightsCardSnapshot: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var scale: CGFloat = 2

    private var renderer: ImageRenderer<InsightsShareImage>?
    private var changes: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var captures = 0

    /// Quiet time after the last change before the picture is taken.
    private static let settle: Duration = .milliseconds(600)
    /// Re-draws allowed while the card keeps changing; then the latest one stands.
    private static let maxCaptures = 6

    func start(_ content: InsightsShareImage, scale: CGFloat) {
        guard renderer == nil else { return }
        let r = ImageRenderer(content: content)
        r.scale = scale
        self.scale = scale
        renderer = r
        changes = r.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        // The first pass puts the card on its feet: its onAppear and tasks start here.
        image = r.cgImage
        schedule()
    }

    private func schedule() {
        guard captures < Self.maxCaptures else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.capture()
        }
    }

    private func capture() {
        guard let renderer else { return }
        captures += 1
        if let new = renderer.cgImage { image = new }
    }

    func stop() {
        pending?.cancel()
        changes = nil
        renderer = nil
    }
}

/// The picture as a PNG file, named for the card and the day ("GlucOS Lows 17 Nov 2026.png").
struct InsightsSharePicture: Transferable {
    let png: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { picture in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("InsightsShare", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(picture.name)
            try picture.png.write(to: file, options: .atomic)
            return SentTransferredFile(file)
        }
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// The sheet: the picture that will be shared, and the button that opens the system share sheet.
struct InsightsSharePreview: View {
    let card: InsightsCard
    let period: InsightsSharePeriod
    /// The card itself, with whatever its view needs from the environment already attached: the
    /// renderer draws it away from the screen's hierarchy.
    let content: AnyView

    @StateObject private var snapshot = InsightsCardSnapshot()
    @State private var now = Date()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    #if os(iOS)
    private let width: CGFloat = 390
    #else
    private let width: CGFloat = 560
    #endif

    private var footer: String { InsightsShare.footer(card: card, period: period, now: now) }

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            HStack {
                Text("Share \(card.title)")
                    .dsFont(.headline)
                Spacer(minLength: DS.Space.md)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                picture
                    .frame(maxWidth: .infinity)
            }
            Text("Only this card and the dates go in the picture. No name or account details.")
                .dsFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            shareButton
        }
        .padding(DS.Space.lg)
        #if os(macOS)
        .frame(width: width + 80, height: 640)
        #endif
        .onAppear {
            snapshot.start(InsightsShareImage(content: AnyView(content.environment(\.colorScheme, colorScheme)),
                                              footer: footer, width: width),
                           scale: max(displayScale, 2))
        }
        .onDisappear { snapshot.stop() }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = snapshot.image {
            Image(decorative: image, scale: snapshot.scale)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: width)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: DS.Stroke.hairline)
                }
                .accessibilityLabel("\(card.title) card. \(footer)")
        } else {
            ProgressView()
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let image = snapshot.image, let png = InsightsSharePicture.png(image) {
            let item = InsightsSharePicture(png: png, name: InsightsShare.fileName(card: card, now: now))
            SwiftUI.ShareLink(item: item,
                              preview: SharePreview("\(card.title) · GlucOS",
                                                    image: Image(decorative: image, scale: snapshot.scale))) {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ds(.primary))
        } else {
            Button {} label: {
                Label("Share…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.ds(.primary))
            .disabled(true)
        }
    }
}
