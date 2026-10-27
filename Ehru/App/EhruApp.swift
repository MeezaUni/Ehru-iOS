import SwiftUI

@main
struct EhruApp: App {
    @State private var library = LibraryStore()
    @State private var player = PlayerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
        }
    }
}
