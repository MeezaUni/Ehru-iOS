import SwiftUI

@main
struct EhruApp: App {
    @State private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            ThemedRoot { RootView() }
                .environment(services.library)
                .environment(services.player)
                .environment(services.actions)
                .environment(services.mixes)
                .environment(services.vybe)
                .environment(services.search)
                .environment(services.router)
                .environment(services.settings)
                .environment(services.sound)
                .environment(services.lyrics)
                .environment(services.transfer)
                .environment(services.fixTags)
                .environment(services.artwork)
                .environment(services.transitions)
                .preferredColorScheme(services.settings.theme.colorScheme)
        }
    }
}
