import Foundation
import Observation

/// Where a track is in the Fix Tags queue.
enum RepairStatus: String, Codable, Sendable {
    case pending, fixing, done, partial, unchanged, needsReview, noMatch, failed, networkFailed, reverted

    var label: String {
        switch self {
        case .pending: "Waiting"
        case .fixing: "Looking up…"
        case .done: "Fixed"
        case .partial: "Partly fixed"
        case .unchanged: "Unchanged"
        case .needsReview: "Needs review"
        case .noMatch: "No match"
        case .failed: "Failed"
        case .networkFailed: "Couldn't reach the providers"
        case .reverted: "Reverted"
        }
    }

    /// Statuses a run (or a resume) looks up; everything else is finished and never redone.
    var toProcess: Bool { self == .pending || self == .networkFailed }
}

/// What a lookup saw, kept as separate fields so the screen never has to piece text back together.
struct RepairDiagnostics: Sendable {
    var fileName: String
    var identity: TrackIdentity
    var outcomes: [ProviderOutcome] = []
    var topCandidates: [MetadataCandidate] = []
    var attempts: [QueryAttempt] = []
    var finalReason: String?
}

/// One track in the queue.
struct RepairItem: Identifiable, Sendable {
    var song: Song
    var status: RepairStatus = .pending
    var reason: String?
    var diagnostics: RepairDiagnostics?
    var changes: [FieldFixPlan.Change] = []
    var notes: [String] = []
    /// A copy of the file as it was before the write, for Revert.
    var backup: URL?

    var id: Int64 { song.id }
}

/// Fix Tags: looks up each queued track online, plans the edit for the chosen fields (see
/// [FieldFixPlanner]), writes it with [TagWriter] and keeps the original so it can be reverted.
/// A lookup that couldn't reach any provider pauses the batch rather than counting as "no match".
@MainActor
@Observable
final class FixTagsStore {
    struct Settings: Codable, Equatable {
        var fields: [String] = MetadataField.allCases.filter { $0 != .filename }.map(\.rawValue)
        var source = MetadataSources.all
        var acceptAt: Float = highConfidenceThreshold
        var orderingFieldsVersion = 1

        enum CodingKeys: String, CodingKey { case fields, source, acceptAt, orderingFieldsVersion }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fields = try values.decodeIfPresent([String].self, forKey: .fields) ?? fields
            source = try values.decodeIfPresent(String.self, forKey: .source) ?? source
            acceptAt = try values.decodeIfPresent(Float.self, forKey: .acceptAt) ?? acceptAt
            // Add ordering to an existing "all fields" setup once, preserving custom selections.
            if !values.contains(.orderingFieldsVersion), Set(fields).isSuperset(of: MetadataField.fillOnlyTags.map(\.rawValue)) {
                for field in [MetadataField.trackNumber, .discNumber] where !fields.contains(field.rawValue) { fields.append(field.rawValue) }
            }
        }
    }

    private(set) var queue: [RepairItem] = []
    private(set) var isRunning = false
    private(set) var pauseReason: String?
    private(set) var settings: Settings

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let service: MetadataService
    @ObservationIgnored private let bpmFinder: BpmFinder
    @ObservationIgnored private let settingsStore = JSONStore<Settings>(name: "fix_tags.json")
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Originals kept for Revert, until the queue is cleared.
    static var backupFolder: URL {
        let url = LibraryPaths.supportFolder.appendingPathComponent("tag-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(library: LibraryStore, service: MetadataService = MetadataService(), bpmFinder: BpmFinder = BpmFinder()) {
        self.library = library
        self.service = service
        self.bpmFinder = bpmFinder
        settings = Settings()
        settings = settingsStore.load() ?? Settings()
        settingsStore.save(settings)
        // Backups of an earlier session belong to a queue that no longer exists.
        try? FileManager.default.removeItem(at: Self.backupFolder)
    }

    var selectedFields: Set<MetadataField> { Set(settings.fields.compactMap(MetadataField.init(rawValue:))) }

    func update(_ edit: (inout Settings) -> Void) {
        edit(&settings)
        settingsStore.save(settings)
    }

    func setField(_ field: MetadataField, _ on: Bool) {
        var fields = selectedFields
        if on { fields.insert(field) } else { fields.remove(field) }
        update { $0.fields = MetadataField.allCases.filter { fields.contains($0) }.map(\.rawValue) }
    }

    var hasWork: Bool { queue.contains { $0.status.toProcess } }
    var revertible: [RepairItem] { queue.filter { $0.backup != nil } }

    func enqueue(_ songs: [Song]) {
        let present = Set(queue.map(\.id))
        queue += songs.filter { !present.contains($0.id) }.map { RepairItem(song: $0) }
    }

    /// Android's "Scan for bad / incomplete tracks": no title, artist or album, or a title carrying
    /// a download site's leftovers.
    nonisolated static func incomplete(_ songs: [Song]) -> [Song] {
        songs.filter { song in
            song.title.isBlank || song.artist.isBlank || song.artist == unknownArtist || song.album.isBlank
                || song.trackNumber <= 0
                || song.album.caseInsensitiveCompare("Unknown Album") == .orderedSame
                || song.title.localizedCaseInsensitiveContains("mp3") || song.title.localizedCaseInsensitiveContains(".com")
        }
    }

    func remove(_ item: RepairItem) {
        guard !isRunning else { return }
        if let backup = item.backup { try? FileManager.default.removeItem(at: backup) }
        queue.removeAll { $0.id == item.id }
    }

    func retry(_ item: RepairItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), !isRunning else { return }
        queue[index].status = .pending
        queue[index].reason = nil
    }

    /// Empties the queue and deletes the kept originals (changes can no longer be reverted).
    func clear() {
        guard !isRunning else { return }
        queue = []
        try? FileManager.default.removeItem(at: Self.backupFolder)
    }

    func pause() { pauseRequested = true }

    func start() {
        guard !isRunning, hasWork else { return }
        let selection = FieldSelection(selectedFields)
        guard !selection.fields.isEmpty else {
            pauseReason = "Choose at least one field to fix"
            return
        }
        isRunning = true
        pauseRequested = false
        pauseReason = nil
        let source = settings.source
        let acceptAt = settings.acceptAt
        task = Task { [weak self] in
            await self?.run(selection: selection, source: source, acceptAt: acceptAt)
        }
    }

    private func run(selection: FieldSelection, source: String, acceptAt: Float) async {
        var wroteAny = false
        for index in queue.indices where queue[index].status.toProcess {
            if pauseRequested {
                pauseReason = "Paused"
                break
            }
            queue[index].status = .fixing
            queue[index].reason = nil
            let item = queue[index]
            let outcome = await lookUp(item, selection: selection, source: source, acceptAt: acceptAt)
            switch outcome {
            case .unreachable(let reason):
                // The track wasn't checked: it goes back as it was, and the batch waits for the connection.
                queue[index].status = .pending
                pauseReason = "\(reason). Nothing more was looked up; resume when you're back online."
                isRunning = false
                if wroteAny { library.scan() }
                return
            case .concluded(var updated, let plan):
                if let request = plan?.request {
                    updated = await write(request, plan: plan!, item: updated)
                    wroteAny = wroteAny || updated.status == .done || updated.status == .partial
                }
                queue[index] = updated
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        isRunning = false
        if wroteAny { library.scan() }
    }

    private enum Lookup {
        case concluded(RepairItem, FieldFixPlan?)
        case unreachable(String)
    }

    private func lookUp(_ item: RepairItem, selection: FieldSelection, source: String, acceptAt: Float) async -> Lookup {
        var item = item
        let url = item.song.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            item.status = .failed
            item.reason = "The file no longer exists"
            return .concluded(item, nil)
        }
        let embedded = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let fileName = url.lastPathComponent
        let cleaned = FilenameCleaner.clean(fileName)
        let identity = TrackIdentity(
            title: usableIdentityText(embedded.title) ?? usableIdentityText(item.song.title),
            artist: usableIdentityText(embedded.artist) ?? usableIdentityText(item.song.artist),
            album: usableIdentityText(embedded.album) ?? usableIdentityText(item.song.album),
            durationMs: item.song.durationMs > 0 ? item.song.durationMs : nil,
            fileTitles: TitleCandidates.generate(fileName),
            fileArtist: usableIdentityText(cleaned.artistGuess)
        )
        let service = service
        let result = await TrackMatcher.match(identity, acceptAt: acceptAt) { query in
            let artist = query.artist.flatMap { $0.lowercased() == query.title.lowercased() ? nil : $0 }
            return await service.search(title: query.title, artist: artist, album: query.album, durationMs: identity.durationMs, selection: source)
        }
        var diagnostics = RepairDiagnostics(fileName: fileName, identity: identity, outcomes: result.outcomes,
                                            topCandidates: Array(result.candidates.prefix(3)), attempts: result.attempts)
        func concluded(_ status: RepairStatus, _ reason: String?, _ plan: FieldFixPlan? = nil) -> Lookup {
            diagnostics.finalReason = reason
            item.status = status
            item.reason = reason
            item.diagnostics = diagnostics
            return .concluded(item, plan)
        }
        if case .confident(let match) = result.decision {
            let plan = await planFix(match, candidates: result.candidates, local: embedded, song: item.song, url: url,
                                     selection: selection, acceptAt: acceptAt)
            item.changes = plan.changes
            item.notes = plan.notes
            if plan.request == nil {
                // Nothing to write is not a fix: say why instead of reporting success.
                return concluded(.unchanged, plan.notes.joined(separator: "; ").nonBlank ?? "The tags already match the online match")
            }
            return concluded(.fixing, nil, plan)
        }
        switch Self.networkVerdict(result.outcomes) {
        case .unreachable(let reason): return .unreachable(reason)
        case .partly(let reason): return concluded(.networkFailed, reason)
        case nil: break
        }
        switch result.decision {
        case .noMatch(let reason):
            if result.candidates.isEmpty, let failure = Self.providerFailureSummary(result.outcomes) {
                return concluded(.failed, failure)
            }
            return concluded(.noMatch, reason ?? "No online match found")
        case .lowConfidence(_, let reason), .ambiguous(_, let reason):
            return concluded(.needsReview, reason)
        case .confident:
            return concluded(.failed, nil)
        }
    }

    /// Plans the edit for a confident match: looks up a genre, a date and a BPM only when the
    /// selection could use them; lookup failures become notes (and "unfilled" reasons), never empty values.
    private func planFix(_ match: MetadataCandidate, candidates: [MetadataCandidate], local embedded: FileTags, song: Song, url: URL,
                         selection: FieldSelection, acceptAt: Float) async -> FieldFixPlan {
        let fields = selection.fields
        let fillOnly = selection.fillOnly
        let local = LocalTrackTags(
            title: embedded.title ?? song.title, artist: embedded.artist ?? song.artist, album: embedded.album ?? song.album,
            genre: Genres.join(embedded.genres), hasArtwork: embedded.hasArtwork, tagsReadable: true,
            year: embedded.dateText, bpm: embedded.bpmText,
            trackNumber: embedded.trackNumber, discNumber: embedded.discNumber
        )
        var reasons: [String: String] = [:]
        var genre: String?
        if fields.contains(.genre) && (!fillOnly || !isUsableTag(local.genre)) {
            switch await service.lookupGenre(match) {
            case .found(let genres, _): genre = Genres.join(genres)
            case .notFound(let reason): reasons["No genre found online"] = "No genre: \(reason)"
            case .failed(let reason): reasons["No genre found online"] = "Genre lookup failed: \(reason)"
            }
        }
        var releaseDate: ReleaseDate?
        if fields.contains(.year) && (!fillOnly || !isUsableYearTag(local.year)) {
            switch releaseDateFor(match, candidates: candidates, confidentScore: acceptAt) {
            case .found(let date): releaseDate = date
            case .rejected(let reason): reasons["No release year found online"] = "No year: \(reason)"
            }
        }
        var bpm: FoundBpm?
        if fields.contains(.bpm) && (!fillOnly || usableBpm(local.bpm) == nil) {
            switch await bpmFinder.find(match, file: url) {
            case .found(let found): bpm = found
            case .notFound(let reason): reasons["No BPM found"] = "No BPM: \(reason)"
            case .failed(let reason): reasons["No BPM found"] = "BPM lookup failed: \(reason)"
            }
        }
        var positioned = match
        var positionNote: String?
        if (fields.contains(.trackNumber) && (!fillOnly || (local.trackNumber ?? 0) <= 0))
            || (fields.contains(.discNumber) && (!fillOnly || (local.discNumber ?? 0) <= 0)) {
            (positioned, positionNote) = await service.withAlbumPosition(match)
            let tied = candidates.filter {
                $0.id != match.id && $0.confidenceScore >= acceptAt
                    && match.confidenceScore - $0.confidenceScore <= tieMargin
                    && albumPositionTitle($0.album) == albumPositionTitle(match.album)
                    && AlbumTrackPosition(disc: $0.discNumber, track: $0.trackNumber).isValid
            }
            if tied.contains(where: { $0.trackNumber != positioned.trackNumber || $0.discNumber != positioned.discNumber }) {
                positioned.trackNumber = 0
                positioned.discNumber = 0
                positionNote = "Equally good matches disagree on album order; track and disc numbers were left unchanged."
            }
        }
        var plan = FieldFixPlanner.plan(fields: fields, fillOnly: fillOnly, local: local, match: positioned, genre: genre,
                                        artwork: nil, releaseDate: releaseDate, bpm: bpm)
        plan.notes = plan.notes.map { reasons[$0] ?? $0 }
        plan.unfilled = Array(reasons.values)
        if let positionNote { plan.notes.append(positionNote) }
        plan.unfilled += plan.notes.filter { $0.hasPrefix("No verified ") || $0.hasPrefix("Kept track number:") || $0.hasPrefix("Kept disc number:") }
        return plan
    }

    /// Writes the planned edit, keeping the original for Revert. A track is marked fixed only once
    /// its file was actually written.
    private func write(_ request: TagWriteRequest, plan: FieldFixPlan, item: RepairItem) async -> RepairItem {
        var item = item
        let url = item.song.url
        let backup = Self.backupFolder.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: url, to: backup)
                do {
                    try TagWriter.write(request, to: url)
                } catch {
                    try? FileManager.default.removeItem(at: backup)
                    throw error
                }
            }.value
            ArtworkLoader.shared.forget(path: url.path)
            item.backup = backup
            item.status = plan.unfilled.isEmpty ? .done : .partial
            item.reason = plan.unfilled.isEmpty ? nil : plan.unfilled.joined(separator: "; ")
        } catch {
            item.status = .failed
            item.reason = error.localizedDescription
        }
        return item
    }

    /// Writes [match], picked by the listener for a track that needed review (or had no confident
    /// match), with the same plan and backup as an automatic fix.
    func apply(_ match: MetadataCandidate, to id: Int64) async {
        guard !isRunning, let start = queue.firstIndex(where: { $0.id == id }) else { return }
        isRunning = true
        defer { isRunning = false }
        var item = queue[start]
        item.status = .fixing
        queue[start] = item
        let url = item.song.url
        let embedded = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let plan = await planFix(match, candidates: item.diagnostics?.topCandidates ?? [match], local: embedded, song: item.song, url: url,
                                 selection: FieldSelection(selectedFields), acceptAt: settings.acceptAt)
        item.changes = plan.changes
        item.notes = plan.notes
        if let request = plan.request {
            item = await write(request, plan: plan, item: item)
        } else {
            item.status = .unchanged
            item.reason = plan.notes.joined(separator: "; ").nonBlank ?? "The tags already match this choice"
        }
        if let index = queue.firstIndex(where: { $0.id == id }) { queue[index] = item }
        if item.status == .done || item.status == .partial { library.scan() }
    }

    /// Puts the selected tracks' files back exactly as they were before their fix.
    func revert(_ ids: Set<Int64>) async {
        guard !isRunning else { return }
        var count = 0
        for index in queue.indices where ids.contains(queue[index].id) {
            guard let backup = queue[index].backup else { continue }
            let url = queue[index].song.url
            do {
                try await Task.detached(priority: .utility) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
                }.value
                ArtworkLoader.shared.forget(path: url.path)
                queue[index].backup = nil
                queue[index].status = .reverted
                queue[index].reason = nil
                count += 1
            } catch {
                queue[index].reason = "Couldn't revert: \(error.localizedDescription)"
            }
        }
        if count > 0 { library.scan() }
    }

    enum NetworkVerdict: Equatable {
        case unreachable(String)
        case partly(String)
    }

    /// If a provider couldn't be reached, the track is not "no match"; nil when every queried provider answered.
    nonisolated static func networkVerdict(_ outcomes: [ProviderOutcome]) -> NetworkVerdict? {
        let unreachable = outcomes.filter { $0.status.isTransient }
        guard !unreachable.isEmpty else { return nil }
        let reason = unreachable.map { "\($0.providerName): \($0.errorMessage ?? $0.status.label)" }.joined(separator: "; ")
        return outcomes.contains { $0.status.answered } ? .partly(reason) : .unreachable(reason)
    }

    /// When every provider that was asked failed rather than answered, the failures.
    nonisolated static func providerFailureSummary(_ outcomes: [ProviderOutcome]) -> String? {
        let considered = outcomes.filter { $0.status != .skipped }
        let failed = considered.filter { !$0.status.answered }
        if considered.isEmpty { return "No provider could be queried for this source" }
        guard failed.count == considered.count else { return nil }
        return "Lookup failed: " + failed.map { "\($0.providerName): \($0.errorMessage ?? $0.status.label)" }.joined(separator: "; ")
    }
}
