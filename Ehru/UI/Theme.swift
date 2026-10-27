import SwiftUI

/// Spacing scale (Android's Spacing: 4/8/12/16/24/32).
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Default horizontal gutter between screen edge and content.
    static let gutter: CGFloat = lg
    /// Wider gutter for hero layouts (Now Playing).
    static let heroGutter: CGFloat = xl
}

enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
}

enum ArtworkSize {
    static let compact: CGFloat = 40
    static let list: CGFloat = 48
    static let miniPlayer: CGFloat = 44
    static let gridMin: CGFloat = 140
    static let shelf: CGFloat = 144
    static let heroMax: CGFloat = 480
}

/// The app's colours, from the Android built-in themes (monochrome, near-black or near-white).
struct AppPalette: Equatable {
    let primary: Color
    let onPrimary: Color
    let background: Color
    let surface: Color
    let surfaceVariant: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let outline: Color

    static let dark = AppPalette(
        primary: Color(argb: 0xFFF8F9FA), onPrimary: Color(argb: 0xFF101216), background: Color(argb: 0xFF101216),
        surface: Color(argb: 0xFF1E222A), surfaceVariant: Color(argb: 0xFF2D3748), onSurface: Color(argb: 0xFFF8F9FA),
        onSurfaceVariant: Color(argb: 0xFFA0AEC0), outline: Color(argb: 0xFF4A5568)
    )
    static let light = AppPalette(
        primary: Color(argb: 0xFF121316), onPrimary: Color(argb: 0xFFFFFFFF), background: Color(argb: 0xFFF4F5F8),
        surface: Color(argb: 0xFFFFFFFF), surfaceVariant: Color(argb: 0xFFE2E8F0), onSurface: Color(argb: 0xFF121316),
        onSurfaceVariant: Color(argb: 0xFF4A5568), outline: Color(argb: 0xFFCBD5E0)
    )
}

/// The theme the listener picked (Settings › Appearance).
enum ThemeChoice: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    /// Android's "Dominant Color": a dark theme tinted by the playing song's cover, or the cover of
    /// the album or playlist page in front.
    case artwork
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System default"
        case .light: "Light"
        case .dark: "Dark"
        case .artwork: "Colours from artwork"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .artwork: .dark
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette.dark
}

extension EnvironmentValues {
    var palette: AppPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Supplies the palette that matches the effective colour scheme, or the artwork's.
struct ThemedRoot<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @ViewBuilder let content: Content
    @State private var artworkPalette: AppPalette?
    @State private var artworkRevision = 0

    var body: some View {
        let followsArtwork = settings.customTheme == nil && settings.theme == .artwork
        let palette = settings.customTheme?.palette
            ?? (followsArtwork ? artworkPalette ?? .dark : (scheme == .dark ? .dark : .light))
        let artworkURL = followsArtwork ? router.focusedArtwork ?? player.state.currentSong?.url : nil
        content
            .environment(\.palette, palette)
            .tint(palette.primary)
            .animation(.easeInOut(duration: 0.6), value: palette)
            .onReceive(NotificationCenter.default.publisher(for: ArtworkLoader.didChange)) { note in
                if note.object as? String == artworkURL?.path { artworkRevision += 1 }
            }
            .task(id: "\(artworkURL?.path ?? "")|\(artworkRevision)") {
                guard let artworkURL else {
                    artworkPalette = nil
                    return
                }
                let image = await ArtworkLoader.shared.image(for: artworkURL, maxPixels: DominantColorExtractor.sampleSize * 2)
                guard !Task.isCancelled else { return }
                artworkPalette = DominantColorExtractor.palette(DominantColorExtractor.colors(of: image))
            }
    }
}

extension View {
    /// While this page is in front, the artwork theme follows [url] instead of the playing song.
    func artworkFocus(_ url: URL?) -> some View { modifier(ArtworkFocus(url: url)) }

    /// A floating glass surface: Liquid Glass on iOS 26, a material elsewhere.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, enabled: Bool = true) -> some View {
        if !enabled {
            self.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.background.secondary))
        } else if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A small press-down scale, like the Android cards' pressScale.
    func pressable() -> some View { buttonStyle(PressScaleStyle()) }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// "1 song", "12 songs".
func countLabel(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

/// m:ss, or h:mm:ss for an hour or more.
func formatDuration(_ ms: Int64) -> String {
    let total = max(ms, 0) / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
}

private struct ArtworkFocus: ViewModifier {
    let url: URL?
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .onAppear { focus(url) }
            .onChange(of: url) { _, new in focus(new) }
            .onDisappear { if router.artworkFocus?.url == url { router.artworkFocus = nil } }
    }

    private func focus(_ url: URL?) {
        router.artworkFocus = url.map { (router.section, $0) }
    }
}
