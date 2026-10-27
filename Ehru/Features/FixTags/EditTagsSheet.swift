import SwiftUI

/// Edits one file's tags by hand, optionally starting from an online match. Only fields that
/// differ from the file's values are written; a blank field keeps what the file has.
struct EditTagsSheet: View {
    let song: Song
    @Environment(FixTagsStore.self) private var fixTags
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var original = FileTags()
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var bpm = ""
    @State private var candidates: [MetadataCandidate] = []
    @State private var searching = false
    @State private var searchNote: String?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Year or date (2019 or 2019-05-17)", text: $year).keyboardType(.numbersAndPunctuation)
                    TextField("Genre (separate several with ;)", text: $genre)
                    TextField("BPM", text: $bpm).keyboardType(.numberPad)
                } footer: {
                    Text("Saved into the file itself (\(song.url.pathExtension.uppercased())). Blank fields keep the file's values.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Search online", systemImage: "magnifyingglass")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(searching || title.isBlank)
                    if let searchNote { Text(searchNote).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(candidates) { candidate in
                        Button { use(candidate) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).foregroundStyle(.primary)
                                Text([candidate.artist, candidate.album, candidate.releaseDate].compactMap { $0?.nonBlank }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(Int(candidate.confidenceScore * 100)) % · \(candidate.sourceName)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Fill from an online match")
                } footer: {
                    Text("Sends only the title, artist, album and length. Tap a match to copy its values into the fields above, then check them before saving.")
                }
            }
            .navigationTitle("Edit tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || request == nil)
                }
            }
            .task { load() }
        }
    }

    private func load() {
        let tags = TagReader.read(song.url)
        original = tags
        title = tags.title ?? song.title
        artist = tags.artist ?? ""
        album = tags.album ?? ""
        year = tags.dateText ?? ""
        genre = Genres.join(tags.genres) ?? ""
        bpm = tags.bpmText ?? ""
    }

    /// Only real changes: unchanged or blank text keeps what the file has.
    private var request: TagWriteRequest? {
        func changed(_ edited: String, _ current: String?) -> String? {
            let value = edited.trimmed
            return value.isEmpty || value == (current ?? "").trimmed ? nil : value
        }
        var request = TagWriteRequest()
        request.title = changed(title, original.title)
        request.artist = changed(artist, original.artist)
        request.album = changed(album, original.album)
        if let date = changed(year, original.dateText) {
            guard let parsed = ReleaseDate.parse(date) else { return nil }
            request.releaseDate = parsed.tagValue
        }
        if let value = changed(genre, Genres.join(original.genres)), !Genres.same(value, Genres.join(original.genres)) {
            request.genre = value
        }
        if let value = changed(bpm, original.bpmText) {
            guard let tempo = Int(value), plausibleBpm.contains(tempo) else { return nil }
            request.bpm = tempo
        }
        return request.hasChanges ? request : nil
    }

    private func search() async {
        searching = true
        searchNote = nil
        let response = await fixTags.service.search(title: title.trimmed, artist: artist.nonBlank, album: album.nonBlank,
                                                    durationMs: song.durationMs > 0 ? song.durationMs : nil, selection: MetadataSources.all)
        candidates = Array(response.candidates.prefix(8))
        if candidates.isEmpty {
            let failures = response.outcomes.filter { !$0.status.answered && $0.status != .skipped }
            searchNote = failures.isEmpty ? "No matches found." : failures.map { "\($0.providerName): \($0.errorMessage ?? $0.status.label)" }.joined(separator: "; ")
        }
        searching = false
    }

    private func use(_ candidate: MetadataCandidate) {
        if isUsableTag(candidate.title) { title = candidate.title }
        if isUsableTag(candidate.artist) { artist = candidate.artist }
        if isUsableTag(candidate.album) { album = candidate.album }
        if let date = candidate.releaseDate { year = date }
        if let tempo = candidate.bpm { bpm = String(tempo) }
        Task {
            if case .found(let genres, _) = await fixTags.service.lookupGenre(candidate), let joined = Genres.join(genres) { genre = joined }
        }
    }

    private func save() async {
        guard let request else { return }
        saving = true
        error = nil
        let url = song.url
        do {
            try await Task.detached(priority: .userInitiated) { try TagWriter.write(request, to: url) }.value
            ArtworkLoader.shared.forget(path: url.path)
            library.scan()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
