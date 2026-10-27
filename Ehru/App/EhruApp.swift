import SwiftUI

@main
struct EhruApp: App {
    @State private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.library)
                .environment(services.player)
        }
    }
}
