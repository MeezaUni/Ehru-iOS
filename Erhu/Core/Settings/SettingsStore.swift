import Foundation
import Observation

/// A Codable value saved as JSON in the app's support folder (Android's proto DataStore).
/// Writes are debounced, so dragging a slider saves once when it settles.
@MainActor
final class JSONStore<Value: Codable & Equatable> {
    private let url: URL
    private var pending: Task<Void, Never>?
    private let debounce: Duration

    init(name: String, debounce: Duration = .milliseconds(400)) {
        url = LibraryPaths.supportFolder.appendingPathComponent(name)
        self.debounce = debounce
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        pending?.cancel()
        let url = self.url
        let delay = debounce
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes at once (e.g. when the app goes to the background).
    func saveNow(_ value: Value) {
        pending?.cancel()
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

/// Transition settings at every level: global master switch and default, per album, per playlist,
/// per pair (Android's TransitionSettingsRepository). Each change touches only its own entry.
@MainActor
@Observable
final class TransitionSettingsStore {
    private struct Stored: Codable, Equatable {
        var global = GlobalTransitionSettings()
        var collections: [String: TransitionChoice] = [:]
        var pairs: [String: TransitionChoice] = [:]
    }

    private(set) var config = TransitionConfig()
    @ObservationIgnored private let store = JSONStore<Stored>(name: "transitions.json")
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        if let stored = store.load() {
            config = TransitionConfig(
                global: stored.global,
                collections: Dictionary(stored.collections.compactMap { key, value in CollectionRef.fromKey(key).map { ($0, value) } },
                                        uniquingKeysWith: { first, _ in first }),
                pairs: Dictionary(stored.pairs.compactMap { key, value in TransitionPairKey.fromKey(key).map { ($0, value) } },
                                  uniquingKeysWith: { first, _ in first })
            )
        }
    }

    func resolve(outgoing: QueueOrigin?, incoming: QueueOrigin?) -> ResolvedTransition {
        TransitionResolver.resolve(config, outgoing: outgoing, incoming: incoming)
    }

    func setGlobal(_ settings: GlobalTransitionSettings) {
        var clean = settings
        clean.defaultChoice = Self.sanitized(settings.defaultChoice)
        if clean.defaultChoice == .inherit { clean.defaultChoice = .off }
        config.global = clean
        changed()
    }

    /// Only [collection] changes; every other album and playlist keeps its own setting.
    func setCollection(_ collection: CollectionRef, _ choice: TransitionChoice) {
        let clean = Self.sanitized(choice)
        config.collections[collection] = clean == .inherit ? nil : clean
        changed()
    }

    /// Only this exact pair changes.
    func setPair(_ pair: TransitionPairKey, _ choice: TransitionChoice) {
        let clean = Self.sanitized(choice)
        config.pairs[pair] = clean == .inherit ? nil : clean
        changed()
    }

    private static func sanitized(_ choice: TransitionChoice) -> TransitionChoice {
        if case .custom(let spec) = choice { return .custom(spec.sanitized()) }
        return choice
    }

    private func changed() {
        store.save(Stored(
            global: config.global,
            collections: Dictionary(uniqueKeysWithValues: config.collections.map { ($0.key.key, $0.value) }),
            pairs: Dictionary(uniqueKeysWithValues: config.pairs.map { ($0.key.key, $0.value) })
        ))
        onChange?()
    }
}
