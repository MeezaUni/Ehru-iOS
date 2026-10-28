import SwiftUI

/// One copy of each control moves between the two-row and compact layouts. The scrolling
/// library never observes the fraction, and its bottom inset stays fixed to avoid feedback.
struct LibraryBottomChrome: View {
    let chrome: LibraryChromeState
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let song = player.state.currentSong
        let fraction = song == nil ? 0 : chrome.fraction
        LibraryChromeLayout(fraction: fraction, hasSong: song != nil) {
            Group {
                if let song {
                    MiniPlayer(song: song, compactness: fraction) {
                        router.showsNowPlaying = true
                    }
                    .frame(height: 60)
                    .chromeSurface(enabled: settings.glassEnabled)
                } else { Color.clear }
            }
            SectionCapsule(chrome: chrome, compactness: fraction)
            Button {
                chrome.expand(reduceMotion: reduceMotion)
                router.showsSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.onSurface)
                    .frame(width: 56, height: 56)
                    .chromeSurface(enabled: settings.glassEnabled)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
        .modifier(ChromeGlassGrouping(enabled: settings.glassEnabled))
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xs)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: song == nil)
    }
}

/// Layout geometry is also used by tests for narrow phones and both endpoints.
struct LibraryChromeGeometry {
    let mini: CGRect
    let navigation: CGRect
    let search: CGRect
    let height: CGFloat

    init(width: CGFloat, fraction: CGFloat, hasSong: Bool) {
        let c = hasSong ? fraction.clamped(0, 1) : 0
        let action: CGFloat = 56, gap: CGFloat = 8, miniHeight: CGFloat = hasSong ? 60 : 0
        height = hasSong ? 124 - 64 * c : 56
        let navWidth = max(action, width - action - gap)
        navigation = CGRect(x: 0, y: hasSong ? 68 * (1 - c) + 2 * c : 0,
                            width: navWidth + (action - navWidth) * c, height: action)
        search = CGRect(x: max(width - action, 0), y: navigation.minY, width: action, height: action)
        mini = CGRect(x: (action + gap) * c, y: 0,
                      width: max(width - 2 * (action + gap) * c, 0), height: miniHeight)
    }
}

private struct LibraryChromeLayout: Layout {
    var fraction: CGFloat
    let hasSong: Bool
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 350
        return CGSize(width: width, height: LibraryChromeGeometry(width: width, fraction: fraction, hasSong: hasSong).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = LibraryChromeGeometry(width: bounds.width, fraction: fraction, hasSong: hasSong)
        for (view, rect) in zip(subviews, [layout.mini, layout.navigation, layout.search]) {
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
    }
}

enum SectionCapsuleGeometry {
    static func position(at x: CGFloat, width: CGFloat, count: Int) -> CGFloat {
        guard width > 8, count > 0 else { return 0 }
        return ((x - 4) / ((width - 8) / CGFloat(count)) - 0.5).clamped(0, CGFloat(count - 1))
    }

    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        Int(position(at: x, width: width, count: count).rounded())
    }
}

private struct SectionCapsule: View {
    let chrome: LibraryChromeState
    let compactness: CGFloat
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var draggedPosition: CGFloat?

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let sections = LibrarySection.allCases
                let selected = sections.firstIndex(of: router.section) ?? 0
                let position = draggedPosition ?? CGFloat(selected)
                let slot = max(geometry.size.width - 8, 1) / CGFloat(sections.count)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.primary.opacity(draggedPosition == nil ? 0.16 : 0.24))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.75))
                        .frame(width: slot, height: 48)
                        .offset(x: 4 + slot * position)
                        .allowsHitTesting(false)
                    HStack(spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                            Button { select(section) } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: router.section == section ? section.selectedIcon : section.icon)
                                        .font(.system(size: 19))
                                    Text(section.label).font(.caption2.weight(.medium)).lineLimit(1)
                                }
                                .foregroundStyle(abs(position - CGFloat(index)) < 0.5 ? palette.primary : palette.onSurfaceVariant)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(router.section == section ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 56)
                .contentShape(Capsule())
                .highPriorityGesture(DragGesture(minimumDistance: 8)
                    .updating($draggedPosition) { value, position, transaction in
                        guard position != nil || abs(value.translation.width) > abs(value.translation.height) else { return }
                        transaction.disablesAnimations = true
                        position = SectionCapsuleGeometry.position(at: value.location.x, width: geometry.size.width, count: sections.count)
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let index = SectionCapsuleGeometry.index(at: value.location.x, width: geometry.size.width, count: sections.count)
                        if sections[index] != router.section { select(sections[index]) }
                    })
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: router.section)
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: draggedPosition == nil)
            }
            .opacity(Double(max(CGFloat(1) - compactness * 2, 0)))
            .allowsHitTesting(compactness < 0.5)
            .accessibilityHidden(compactness >= 0.5)
            Button { chrome.expand(reduceMotion: reduceMotion) } label: {
                Image(systemName: router.section.selectedIcon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(Double(max(compactness * 2 - CGFloat(1), 0)))
            .allowsHitTesting(compactness >= 0.5)
            .accessibilityHidden(compactness < 0.5)
            .accessibilityLabel("Expand sections, \(router.section.label)")
        }
        .frame(height: 56)
        .chromeSurface(enabled: settings.glassEnabled)
    }

    private func select(_ section: LibrarySection) {
        router.select(section)
        chrome.expand(reduceMotion: reduceMotion)
    }
}

private struct ChromeGlassGrouping: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled {
            GlassEffectContainer(spacing: 8) { content }
        } else { content }
    }
}

extension View {
    /// Explicitly clip both material and content, including the mini player's progress line.
    func chromeSurface(enabled: Bool) -> some View {
        glassSurface(cornerRadius: 30, enabled: enabled)
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}
