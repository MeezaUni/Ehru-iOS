import Foundation

/// The app's long-lived objects (Android's Hilt singletons).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let database: LibraryDatabase
    let library: LibraryStore
    let transitions: TransitionSettingsStore
    let player: PlayerController
    let vybe: VybeStore
    let mixes: MixStore
    let actions: LibraryActions
    let search: SearchStore
    let router: AppRouter
    let settings: AppSettings
    let sound: SoundStore

    private init() {
        // A database that cannot be opened falls back to memory: the app still works this session.
        database = (try? LibraryDatabase.open()) ?? (try! LibraryDatabase.inMemory())
        library = LibraryStore(database: database)
        transitions = TransitionSettingsStore()
        player = PlayerController(database: database, transitions: transitions)
        vybe = VybeStore(database: database, player: player)
        mixes = MixStore(database: database, vybe: vybe.engine)
        actions = LibraryActions(database: database, player: player, mixes: mixes)
        search = SearchStore(library: library)
        settings = AppSettings()
        sound = SoundStore(kernel: player.engine.eqKernel)
        router = AppRouter()
        router.section = settings.startSection
    }
}
