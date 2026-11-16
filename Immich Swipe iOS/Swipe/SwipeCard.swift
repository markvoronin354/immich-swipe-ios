import AVFoundation
import SwiftUI

/// One photo card, laid out like the Android app: action buttons in the corners the user chose.
/// Deciding is done by swiping, by the bottom bar, or by tapping the edges.
struct SwipeCard: View {
    let asset: Asset
    let imageRequest: URLRequest
    var rotation = 0
    /// The original image, drawn over the preview once it has loaded.
    var fullResolutionRequest: URLRequest?
    /// The player whose video should be drawn over the preview, when this card is the playing video.
    var player: AVPlayer?
    /// The pending gesture outcome, for the stamp. Nil when not dragging past a threshold.
    var intent: SwipeIntent?
    /// 0…1, how far the drag is towards committing, for the stamp's opacity.
    var intentStrength: Double = 0
    /// The buttons drawn over this card, so the stamp can stay clear of them.
    var buttonLayout: CardButtonLayout?
    /// Nil for the card waiting behind, which shows no controls.
    var actions: SwipeCardActions?
    /// Faded out by a long press; still laid out, so nothing moves.
    var controlsHidden = false
    /// Pinch zoom of the media (1 = fitted) and how far it has been dragged while zoomed.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// Reports whether the original is still downloading.
    var isLoadingOriginal: Binding<Bool>?

    var body: some View {
        ZStack {
            CardMedia(preview: imageRequest, original: fullResolutionRequest, player: player, rotation: rotation, isLoadingOriginal: isLoadingOriginal)
                .scaleEffect(zoom)
                .offset(pan)

            if let actions {
                // An overlay on the card's own size, so a long row of corner buttons can't widen the card.
                Color.clear.overlay {
                    CardControls(asset: asset, actions: actions)
                        .opacity(controlsHidden ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: controlsHidden)
                }
            }

            if let intent {
                let insets = IntentStamp.cardInsets(for: intent, layout: buttonLayout, isVideo: asset.type == .video)
                IntentStamp(intent: intent, isCommitted: intentStrength >= 1)
                    // Android: up to 90% opaque.
                    .opacity(intentStrength * 0.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: intent.stampAlignment)
                    .padding(.top, insets.top)
                    .padding(.horizontal, insets.side)
                    .allowsHitTesting(false)
            }
        }
        // The bars around a fitted asset. Android fills them with the card's container colour, a light grey in
        // light mode (surfaceContainerHighest); dark mode stays black.
        .background(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .systemGray5 }))
        .clipShape(.rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

/// What the on-card buttons do, and where they sit. Supplied by the deck screen.
struct SwipeCardActions {
    var layout: CardButtonLayout
    var rotate: () -> Void
    var openInImmich: () -> Void
    /// Opens the other of app / web, on a long press of the Immich button.
    var openInImmichElsewhere: () -> Void
    var fullscreen: () -> Void
    var isMuted: Bool
    var toggleMute: () -> Void
    var isDownloading: Bool
    var download: () -> Void
    var shareItem: ShareableAsset
    var isFullResolution: Bool
    /// The original is on its way; the button shows a spinner until it arrives.
    var isLoadingFullResolution = false
    var toggleFullResolution: () -> Void
    /// The file size, set only while the deck is sorted by size.
    var sizeText: String?
    /// The deck's player, set only while it is playing this card's video.
    var video: DeckVideoPlayer?
}

/// The preview, the original over it when asked for, and the playing video over both, all turned in
/// 90° steps and sized so they still fit the card when sideways.
private struct CardMedia: View {
    let preview: URLRequest
    let original: URLRequest?
    let player: AVPlayer?
    let rotation: Int
    var isLoadingOriginal: Binding<Bool>?

    var body: some View {
        GeometryReader { geometry in
            let sideways = rotation % 180 != 0
            ZStack {
                RemoteImage(request: preview)
                if let original {
                    RemoteImage(request: original, maxPixelSize: 4096, isOverlay: true, isLoading: isLoadingOriginal)
                }
                if let player {
                    PlayerSurface(player: player)
                }
            }
            .frame(
                width: sideways ? geometry.size.height : geometry.size.width,
                height: sideways ? geometry.size.width : geometry.size.height
            )
            .rotationEffect(.degrees(Double(rotation)))
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.snappy, value: rotation)
        }
    }
}

/// The corner buttons. Drawn beside the card rather than inside it when the card carries tap and drag
/// gestures, because those gestures would otherwise take the touches meant for the buttons.
struct CardControls: View {
    let asset: Asset
    let actions: SwipeCardActions

    @State private var cardWidth: CGFloat = 0
    @State private var topLeftSize: CGSize = .zero
    @State private var topRightSize: CGSize = .zero
    @State private var sizeWidth: CGFloat = 0
    @State private var bottomLeftSize: CGSize = .zero
    @State private var bottomRightSize: CGSize = .zero
    @State private var infoWidth: CGFloat = 0

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                CornerButtons(corner: .topLeft, asset: asset, actions: actions)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { topLeftSize = $0 }
                Spacer()
                CornerButtons(corner: .topRight, asset: asset, actions: actions)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { topRightSize = $0 }
            }

            Spacer()

            HStack(alignment: .bottom) {
                CornerButtons(corner: .bottomLeft, asset: asset, actions: actions)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { bottomLeftSize = $0 }
                Spacer()
                CornerButtons(corner: .bottomRight, asset: asset, actions: actions)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { bottomRightSize = $0 }
            }
        }
        // 8 pt, the same inset as the centred pills, so the buttons' outer edges line up with them.
        .padding(8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
        // The size while sorting by size, top centre for photos and videos alike, as on Android.
        .overlay(alignment: .top) {
            if let sizeText = actions.sizeText {
                Text(sizeText)
                    .modifier(CardPillText())
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sizeWidth = $0 }
                    .padding(.top, clearance(of: sizeWidth, from: (.topLeft, topLeftSize), (.topRight, topRightSize)))
                    .animation(.snappy, value: clearance(of: sizeWidth, from: (.topLeft, topLeftSize), (.topRight, topRightSize)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if asset.type == .video, let video = actions.video, video.duration > 0 {
                TimePill(video: video)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { infoWidth = $0 }
                    .padding(.bottom, clearance(of: infoWidth, from: (.bottomLeft, bottomLeftSize), (.bottomRight, bottomRightSize)))
                    .animation(.snappy, value: clearance(of: infoWidth, from: (.bottomLeft, bottomLeftSize), (.bottomRight, bottomRightSize)))
            }
        }
        .overlay {
            // While the video is paused from its time pill, as on Android.
            if let video = actions.video, !video.isPlaying {
                Image(systemName: "pause.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 64, height: 64)
                    .modifier(CardPillBackground())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8)),
                        removal: .opacity.combined(with: .scale(scale: 1.2))
                    ))
            }
        }
        .animation(.snappy, value: actions.video?.isPlaying)
    }

    /// How far a centred pill sits from the card's top or bottom edge: 8 pt, as on Android, or, when it
    /// would overlap a corner's buttons on that edge, past them with a gap of 8 pt (`clearOfCornerButtons`).
    private func clearance(of pillWidth: CGFloat, from first: (IconPosition, CGSize), _ second: (IconPosition, CGSize)) -> CGFloat {
        let isVideo = asset.type == .video
        // A corner that has lost its buttons may keep its last measured size, so empty corners count as zero.
        let sizes = [first, second].map { actions.layout.buttons(in: $0.0, isVideo: isVideo).isEmpty ? .zero : $0.1 }
        let corner = sizes.map(\.width).max() ?? 0
        let room = (cardWidth - pillWidth) / 2 - 8
        guard corner > 0, corner > room else { return 8 }
        return 8 + (sizes.map(\.height).max() ?? 0) + 8
    }
}

/// Play/pause and "0:12 / 1:30" (`PlayPauseTimePill`). Tapping it is the only way to pause the card's
/// video, as on Android. Shown once the player knows the length, so only on the top card.
private struct TimePill: View {
    let video: DeckVideoPlayer

    var body: some View {
        Button(action: video.togglePlayPause) {
            HStack(spacing: 8) {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text("\(Self.mediaTime(video.currentTime)) / \(Self.mediaTime(video.duration))")
                    .monospacedDigit()
            }
            .font(.subheadline.bold())
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .modifier(CardPillBackground())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(video.isPlaying ? "Pause" : "Play")
        .accessibilityValue(Text("\(Self.mediaTime(video.currentTime)) of \(Self.mediaTime(video.duration))"))
    }

    /// "1:05", or "1:02:05" past an hour, as on Android (`formatMediaTime`).
    static func mediaTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (hours, minutes, secs) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

private struct CardPillText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.bold())
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .modifier(CardPillBackground())
    }
}

/// The card buttons' blurred material rather than Liquid Glass, which swells while the card moves.
private struct CardPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background(.black.opacity(0.35), in: .capsule)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
    }
}

/// The buttons assigned to one corner, stacked the way the user chose.
private struct CornerButtons: View {
    let corner: IconPosition
    let asset: Asset
    let actions: SwipeCardActions

    var body: some View {
        let buttons = actions.layout.buttons(in: corner, isVideo: asset.type == .video)
        if !buttons.isEmpty {
            let stack = actions.layout.orientation == .vertical
                ? AnyLayout(VStackLayout(alignment: corner.isLeading ? .leading : .trailing, spacing: 12))
                : AnyLayout(HStackLayout(alignment: corner.isTop ? .top : .bottom, spacing: 12))
            stack {
                ForEach(buttons, id: \.self) { button in
                    view(for: button)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for button: CardButton) -> some View {
        switch button {
        case .fullscreen:
            CardIconButton(title: "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: actions.fullscreen)
        case .rotate:
            CardIconButton(title: "Rotate", systemImage: "arrow.clockwise", action: actions.rotate)
        case .immich:
            // Not a Button: a Button only fires on release, and holding should open the other mode once the press
            // is long enough. A completed long press cancels the tap, so only one of the two runs.
            CardIconLabel(title: "Open in Immich", systemImage: "arrow.up.forward.square")
                .contentShape(.circle)
                .onTapGesture(perform: actions.openInImmich)
                .onLongPressGesture(minimumDuration: 0.4, perform: actions.openInImmichElsewhere)
                .accessibilityAddTraits(.isButton)
        case .mute:
            CardIconButton(
                title: actions.isMuted ? "Unmute" : "Mute",
                systemImage: actions.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                action: actions.toggleMute
            )
        case .download:
            if actions.isDownloading {
                CardIconLabel(title: "Downloading", isBusy: true)
            } else {
                CardIconButton(title: "Download", systemImage: "arrow.down.to.line", action: actions.download)
            }
        case .share:
            ShareLink(item: actions.shareItem, preview: SharePreview(actions.shareItem.fileName)) {
                CardIconLabel(title: "Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        case .fullResolution:
            CardIconButton(
                title: "Full Resolution",
                systemImage: CardGlyph.hd,
                isActive: actions.isFullResolution,
                isBusy: actions.isLoadingFullResolution,
                action: actions.toggleFullResolution
            )
        }
    }
}

/// A button's icon: an SF Symbol, or a drawn "HD" badge, which SF Symbols doesn't have.
struct CardGlyph: View {
    static let hd = "hd"

    let name: String
    /// Draws the "HD" badge solid with the letters cut out, for an on state.
    var isFilled = false

    var body: some View {
        if name == Self.hd {
            let badge = Text("HD")
                .font(.system(.caption2, design: .rounded, weight: .heavy))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
            if isFilled {
                badge
                    .blendMode(.destinationOut)
                    .background { RoundedRectangle(cornerRadius: 5) }
                    .compositingGroup()
            } else {
                badge.overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(lineWidth: 1.75) }
            }
        } else {
            Image(systemName: name)
        }
    }
}

/// The look shared by every round button on the card.
private struct CardIconLabel: View {
    let title: LocalizedStringKey
    var systemImage = ""
    var isActive = false
    var isBusy = false

    var body: some View {
        Group {
            if isBusy {
                ProgressView().tint(.white)
            } else {
                Label { Text(title) } icon: { CardGlyph(name: systemImage) }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    // The arrowhead pokes above the arc, so centring the symbol leaves the arc low in the circle.
                    .offset(y: systemImage == "arrow.clockwise" ? -2 : 0)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        // A blurred material, not Liquid Glass: glass reacts to the card's movement and swelled up while the
        // card was dragged or flew off. A material stays the same size whatever the card does.
        .background(isActive ? Color.accentColor.opacity(0.6) : .black.opacity(0.35), in: .circle)
        .background(.ultraThinMaterial, in: .circle)
        .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
        .accessibilityLabel(Text(title))
    }
}

private struct CardIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isActive = false
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CardIconLabel(title: title, systemImage: systemImage, isActive: isActive, isBusy: isBusy)
        }
        .buttonStyle(.plain)
    }
}

/// What releasing the drag would do right now.
enum SwipeIntent: Equatable {
    case keep, delete, undo

    var stampAlignment: Alignment {
        switch self {
        case .keep: .topLeading
        case .delete: .topTrailing
        case .undo: .top
        }
    }
}

/// The Keep / Delete / Undo label shown while dragging, after Android's `IndicatorBadge`: the bare word in
/// heavy rounded type and the intent's colour, with no container. It springs in from 60% and pops to 112%,
/// with a tick, once the drag is far enough to commit.
struct IntentStamp: View {
    let intent: SwipeIntent
    /// True once letting go would carry out the intent.
    var isCommitted = false

    @State private var hasAppeared = false

    var body: some View {
        Text(title)
            .font(.system(.largeTitle, design: .rounded, weight: .black))
            .foregroundStyle(color)
            // A soft light halo and drop shadow keep the word legible on any photo.
            .shadow(color: .white.opacity(0.5), radius: 2)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .scaleEffect(hasAppeared ? (isCommitted ? 1.12 : 1) : 0.6)
            .animation(.spring(duration: 0.35, bounce: 0.4), value: hasAppeared)
            .animation(.spring(duration: 0.35, bounce: 0.4), value: isCommitted)
            .sensoryFeedback(.selection, trigger: isCommitted) { _, committed in committed }
            .onAppear { hasAppeared = true }
            .accessibilityHidden(true)
    }

    private var title: LocalizedStringKey {
        switch intent {
        case .keep: "KEEP"
        case .delete: "DELETE"
        case .undo: "UNDO"
        }
    }

    private var color: Color {
        switch intent {
        case .keep: .green
        case .delete: .red
        case .undo: .blue
        }
    }

    /// Where the badge sits on the card: Android's 60 pt from the top and the side, moved clear of the
    /// card buttons it would land on. A row of buttons along the top can reach across the card from either
    /// corner, so any top row pushes every badge down. A column stays at its own side, so it only pushes in
    /// the badge that shares its corner: Keep top-left, Delete top-right. Undo sits in the middle, which a
    /// column never reaches.
    static func cardInsets(for intent: SwipeIntent, layout: CardButtonLayout?, isVideo: Bool) -> (top: CGFloat, side: CGFloat) {
        // A corner's buttons are 48 pt circles, 16 pt from the edge; the badge keeps 12 pt from them.
        let clear: CGFloat = 16 + 48 + 12
        let android: CGFloat = 60
        guard let layout else { return (android, android) }
        func hasButtons(_ corner: IconPosition) -> Bool { !layout.buttons(in: corner, isVideo: isVideo).isEmpty }

        if layout.orientation == .horizontal {
            return hasButtons(.topLeft) || hasButtons(.topRight) ? (clear, android) : (android, android)
        }
        let ownCorner: IconPosition? = switch intent {
        case .keep: .topLeft
        case .delete: .topRight
        case .undo: nil
        }
        guard let ownCorner, hasButtons(ownCorner) else { return (android, android) }
        return (android, clear)
    }
}

/// The "Image details" panel that slides up from the bottom of the card, as on Android (`MetadataPanel.kt`).
/// A frosted sheet rather than Android's tinted blur, so it reads like an iOS info panel.
struct MetadataPanel: View {
    let asset: Asset
    /// Nil while loading.
    let albumNames: [String]?
    let onClose: () -> Void
    /// Sends the new description to the server; throws when it couldn't be saved.
    let saveDescription: (String) async throws -> Void

    @State private var isEditingDescription = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack {
                Text(asset.type == .video ? "Video details" : "Image details")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.fill.tertiary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                DescriptionRow(description: description) { isEditingDescription = true }
                Divider().padding(.leading, 36)
                MetadataRow(title: "Date", systemImage: "calendar", value: date)
                Divider().padding(.leading, 36)
                MetadataRow(title: "Format", systemImage: "info.circle", value: format)
                Divider().padding(.leading, 36)
                MetadataRow(title: "Size", systemImage: "internaldrive", value: size)
                Divider().padding(.leading, 36)
                MetadataRow(title: "Resolution", systemImage: "aspectratio", value: resolution)
                Divider().padding(.leading, 36)
                MetadataRow(title: "Camera", systemImage: "camera", value: camera)
                Divider().padding(.leading, 36)
                MetadataRow(title: "Albums", systemImage: "rectangle.stack", value: albums)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        // All corners match the card's 28 pt corners. The deck's rounded clip doesn't round the material,
        // so its bottom corners have to be rounded here too or they poke out past the card's.
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .sheet(isPresented: $isEditingDescription) {
            DescriptionEditor(initial: asset.exifInfo?.description ?? "", save: saveDescription)
        }
    }

    /// Nil when there's no description, or it's only whitespace, as on Android.
    private var description: String? {
        guard let text = asset.exifInfo?.description, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private var date: String {
        // Immich dates are ISO 8601, with or without fractional seconds.
        let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(asset.fileCreatedAt))
            ?? (try? Date.ISO8601FormatStyle().parse(asset.fileCreatedAt))
        guard let date = parsed else { return String(localized: "N/A") }
        return date.formatted(date: .long, time: .omitted)
    }

    /// "Image (.PNG)", or just "Image" when the file name has no extension.
    private var format: String {
        let type = switch asset.type {
        case .image: String(localized: "Image")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .other: String(localized: "Other")
        }
        guard let name = asset.originalFileName, let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else { return type }
        return "\(type) (.\(name[name.index(after: dot)...].uppercased()))"
    }

    private var size: String {
        guard let exif = asset.exifInfo else { return String(localized: "Loading…") }
        guard let bytes = exif.fileSizeInByte else { return String(localized: "N/A") }
        return bytes.formatted(.byteCount(style: .file))
    }

    private var resolution: String {
        guard let exif = asset.exifInfo else { return String(localized: "Loading…") }
        let width = exif.exifImageWidth.map(String.init) ?? "?"
        let height = exif.exifImageHeight.map(String.init) ?? "?"
        return "\(width) × \(height)"
    }

    private var camera: String {
        guard let exif = asset.exifInfo else { return String(localized: "Loading…") }
        return Self.cameraName(make: exif.make, model: exif.model) ?? String(localized: "N/A")
    }

    /// Words companies tack onto the EXIF make, dropped from its end: "OLYMPUS IMAGING CORP." reads "OLYMPUS".
    private static let companySuffixes: Set<String> = [
        "corporation", "corp", "co", "company", "ltd", "limited", "inc", "incorporated", "llc", "plc",
        "gmbh", "ag", "ab", "sa", "imaging", "optical", "photo", "electronics", "camera",
    ]

    /// "Apple iPhone 15 Pro". The make loses company words, and is dropped when the model already starts
    /// with one of its words, so "NIKON CORPORATION" and "NIKON D7000" read "NIKON D7000".
    static func cameraName(make: String?, model: String?) -> String? {
        var words = (make ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        while words.count > 1, let last = words.last,
              companySuffixes.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        let brand = words.joined(separator: " ")
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return brand.isEmpty ? nil : brand }
        // Samsung only exposes model codes; show the marketing name and keep the code, as Android does.
        // Some phones repeat the make in the model, as in "SAMSUNG-SM-G900A".
        if brand.localizedCaseInsensitiveContains("samsung") {
            var code = Substring(model)
            if code.lowercased().hasPrefix("samsung") { code = code.dropFirst("samsung".count).drop { " -_".contains($0) } }
            if let name = SamsungModels.name(for: String(code)) { return "\(name) (\(code))" }
        }
        let modelFirstWord = model.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if brand.isEmpty || words.contains(where: { $0.lowercased() == modelFirstWord }) { return model }
        return "\(brand) \(model)"
    }

    private var albums: String {
        guard let albumNames else { return String(localized: "Loading…") }
        return albumNames.isEmpty ? String(localized: "None") : albumNames.formatted(.list(type: .and, width: .narrow))
    }
}

/// The description, or a prompt to add one. It can run to several lines, so the icon stays beside the first.
private struct DescriptionRow: View {
    let description: String?
    let action: () -> Void

    var body: some View {
        // A tap gesture rather than a Button: a Button holds on to the touch, so a drag starting here
        // wouldn't move the panel until the finger lifted.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(description ?? String(localized: "Add a description"))
                .foregroundStyle(description == nil ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityLabel("Description")
        .accessibilityValue(description ?? "")
        .accessibilityHint("Add a description")
    }
}

/// Android's description dialog: 3 to 6 lines, Save only once the trimmed text changed, and locked while
/// the request runs so it can't be saved twice or closed mid-request. A sheet rather than an alert, since
/// iOS alerts only take a single line.
private struct DescriptionEditor: View {
    let initial: String
    let save: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var failed = false
    @FocusState private var isFocused: Bool

    init(initial: String, save: @escaping (String) async throws -> Void) {
        self.initial = initial
        self.save = save
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !isSaving && trimmed != initial.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add a description", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                        .focused($isFocused)
                        .disabled(isSaving)
                } footer: {
                    if failed {
                        Text("Couldn't save the description").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Description")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: submit)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
        .onAppear { isFocused = true }
    }

    private func submit() {
        isSaving = true
        failed = false
        Task {
            do {
                try await save(trimmed)
                dismiss()
            } catch {
                isSaving = false
                failed = true
            }
        }
    }
}

private struct MetadataRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
