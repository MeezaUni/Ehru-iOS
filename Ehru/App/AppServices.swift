import Foundation

/// The app's long-lived objects (Android's Hilt singletons).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let database: LibraryDatabase
    let library: LibraryStore

    private init() {
        // A database that cannot be opened falls back to memory: the app still works this session.
        database = (try? LibraryDatabase.open()) ?? (try! LibraryDatabase.inMemory())
        library = LibraryStore(database: database)
    }
}
