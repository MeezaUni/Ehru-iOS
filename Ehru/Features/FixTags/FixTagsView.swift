import SwiftUI

/// Auto Fix Tags: a queue of tracks, the fields to fix and the source, Start / Pause, each track's
/// outcome with what was looked up, and Revert for the tracks that were changed.
struct FixTagsView: View {
    @Environment(FixTagsStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var addingSongs = false
    @State private var selectedForRevert = Set<Int64>()
    @State private var detail: RepairItem?
    @State private var confirmingClear = false

    var body: some View {
        List {
            optionsSection
            statusSection
            queueSection
        }
        .navigationTitle("Fix tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addingSongs = true } label: { Label("Add songs", systemImage: "plus") }
                        .disabled(store.isRunning)
                    if !store.revertible.isEmpty {
                        Button {
                            Task { await store.revert(selectedForRevert.isEmpty ? Set(store.revertible.map(\.id)) : selectedForRevert) }
                            selectedForRevert = []
                        } label: {
                            Label(selectedForRevert.isEmpty ? "Revert all changes" : "Revert \(selectedForRevert.count)", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(store.isRunning)
                    }
                    Button(role: .destructive) { confirmingClear = true } label: { Label("Clear queue", systemImage: "trash") }
                        .disabled(store.isRunning || store.queue.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Queue options")
            }
        }
        .sheet(isPresented: $addingSongs) { AddSongsSheet { store.enqueue($0) } }
        .sheet(item: $detail) { item in RepairItemDetail(item: item) }
        .confirmationDialog("Clear the queue?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                store.clear()
                selectedForRevert = []
            }
        } message: {
            Text("The kept originals are deleted too, so the changes can no longer be reverted.")
        }
    }

    private var optionsSection: some View {
        Section {
            ForEach(MetadataField.allCases.filter { $0 != .filename }) { field in
                Toggle(field.displayName, isOn: Binding(get: { store.selectedFields.contains(field) }, set: { store.setField(field, $0) }))
                    .disabled(store.isRunning)
            }
            Picker("Source", selection: Binding(get: { store.settings.source }, set: { value in store.update { $0.source = value } })) {
                ForEach(MetadataSources.options, id: \.key) { Text($0.label).tag($0.key) }
            }
            .disabled(store.isRunning)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Write a match from \(Int((store.settings.acceptAt * 100).rounded())) % confidence")
                Slider(value: Binding(get: { Double(store.settings.acceptAt) }, set: { value in store.update { $0.acceptAt = Float(value) } }),
                       in: 0.7...0.99, step: 0.01)
            }
            .disabled(store.isRunning)
        } header: {
            Text("What to fix")
        } footer: {
            Text(FieldSelection(store.selectedFields).fillOnly
                ? "All fields: the title is corrected; artist, album, year and genre are only filled in where the file has none, so your library's grouping never changes. BPM only fills a missing tempo."
                : "Selected fields are replaced with the match's values. A found BPM only fills a missing tempo.")
        }
    }

    private var statusSection: some View {
        Section {
            if store.isRunning {
                HStack {
                    ProgressView()
                    Text("Looking up \(store.queue.filter { $0.status == .fixing }.first?.song.title ?? "")…").lineLimit(1)
                    Spacer()
                    Button("Pause") { store.pause() }
                }
            } else {
                Button {
                    store.start()
                } label: {
                    Label(store.queue.contains { $0.status != .pending && $0.status.toProcess } ? "Resume" : "Start", systemImage: "play.fill")
                }
                .disabled(!store.hasWork)
            }
            if let reason = store.pauseReason {
                Text(reason).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
            }
            if !store.queue.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
            }
        } footer: {
            Text("Searches iTunes, MusicBrainz and Deezer with the track's title, artist, album and length (and its file name when the tags are missing). Your music is never uploaded. Each changed file's original is kept until you clear the queue, so it can be reverted.")
        }
    }

    private var summary: String {
        let counts = Dictionary(grouping: store.queue, by: \.status).mapValues(\.count)
        let order: [RepairStatus] = [.done, .partial, .unchanged, .needsReview, .noMatch, .failed, .networkFailed, .reverted, .pending]
        return order.compactMap { status in counts[status].map { "\($0) \(status.label.lowercased())" } }.joined(separator: " · ")
    }

    private var queueSection: some View {
        Section("Queue") {
            if store.queue.isEmpty {
                Text("Add songs here, or choose \"Fix tags online\" in any song's menu.")
                    .font(.footnote).foregroundStyle(palette.onSurfaceVariant)
            }
            ForEach(store.queue) { item in
                HStack(spacing: Spacing.md) {
                    if item.backup != nil {
                        Button {
                            if selectedForRevert.contains(item.id) { selectedForRevert.remove(item.id) } else { selectedForRevert.insert(item.id) }
                        } label: {
                            Image(systemName: selectedForRevert.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selectedForRevert.contains(item.id) ? "Selected for revert" : "Select for revert")
                    }
                    Button { detail = item } label: { RepairRow(item: item) }
                        .buttonStyle(.plain)
                }
                .swipeActions {
                    if !store.isRunning {
                        Button(role: .destructive) { store.remove(item) } label: { Label("Remove", systemImage: "trash") }
                        if item.status != .pending && item.status != .fixing {
                            Button { store.retry(item) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.blue)
                        }
                    }
                }
            }
        }
    }
}

private struct RepairRow: View {
    let item: RepairItem
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.md) {
            SongArtworkView(song: item.song, maxPixels: 120)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title).lineLimit(1)
                Text(item.song.subtitle).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                if let reason = item.reason ?? item.changes.first.map({ "\($0.field.rawValue.capitalized): \($0.newValue)" }) {
                    Text(reason).font(.caption2).foregroundStyle(palette.onSurfaceVariant).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            StatusBadge(status: item.status)
        }
        .contentShape(Rectangle())
    }
}

private struct StatusBadge: View {
    let status: RepairStatus

    var body: some View {
        if status == .fixing {
            ProgressView()
        } else {
            Image(systemName: icon).foregroundStyle(color).accessibilityLabel(status.label)
        }
    }

    private var icon: String {
        switch status {
        case .pending: "clock"
        case .fixing: "hourglass"
        case .done: "checkmark.circle.fill"
        case .partial: "checkmark.circle"
        case .unchanged: "equal.circle"
        case .needsReview: "questionmark.circle"
        case .noMatch: "magnifyingglass"
        case .failed: "exclamationmark.triangle"
        case .networkFailed: "wifi.exclamationmark"
        case .reverted: "arrow.uturn.backward.circle"
        }
    }

    private var color: Color {
        switch status {
        case .done, .partial: .green
        case .failed, .networkFailed: .red
        case .needsReview: .orange
        default: .secondary
        }
    }
}

/// What one lookup saw: the track's identity, each query and every provider's answer, the best
/// candidates and the changes made (or why none were).
private struct RepairItemDetail: View {
    let item: RepairItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Result") {
                    LabeledContent("Status", value: item.status.label)
                    if let reason = item.reason { Text(reason).font(.footnote) }
                }
                if !item.changes.isEmpty {
                    Section("Changes") {
                        ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.field.rawValue.capitalized).font(.caption.weight(.semibold))
                                Text("\(change.oldValue ?? "—") → \(change.newValue)").font(.footnote)
                            }
                        }
                    }
                }
                if !item.notes.isEmpty {
                    Section("Left alone") {
                        ForEach(item.notes, id: \.self) { Text($0).font(.footnote) }
                    }
                }
                if let diagnostics = item.diagnostics {
                    Section("The file") {
                        LabeledContent("File", value: diagnostics.fileName)
                        LabeledContent("Title", value: diagnostics.identity.title ?? "—")
                        LabeledContent("Artist", value: diagnostics.identity.artist ?? diagnostics.identity.fileArtist ?? "—")
                        LabeledContent("Album", value: diagnostics.identity.album ?? "—")
                        if !diagnostics.identity.fileTitles.isEmpty {
                            LabeledContent("From the file name", value: diagnostics.identity.fileTitles.joined(separator: " · "))
                        }
                    }
                    ForEach(Array(diagnostics.attempts.enumerated()), id: \.offset) { index, attempt in
                        Section("Search \(index + 1) (\(attempt.source))") {
                            Text([attempt.title, attempt.artist, attempt.album.map { "album: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                            ForEach(Array(attempt.outcomes.enumerated()), id: \.offset) { _, outcome in
                                LabeledContent(outcome.providerName) {
                                    Text(outcome.candidateCount > 0 ? "\(outcome.candidateCount) · \(outcome.status.label)" : outcome.errorMessage ?? outcome.status.label)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    if !diagnostics.topCandidates.isEmpty {
                        Section("Best candidates") {
                            ForEach(diagnostics.topCandidates) { candidate in
                                Text(TrackMatcher.describe(candidate, diagnostics.identity)).font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle(item.song.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Picks songs to add to the queue: search, select, or add everything shown.
private struct AddSongsSheet: View {
    let onAdd: ([Song]) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = Set<Int64>()

    var body: some View {
        let shown = filtered
        NavigationStack {
            List(shown) { song in
                Button {
                    if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            Text(song.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("Add songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add all \(shown.count)" : "Add \(selected.count)") {
                        onAdd(selected.isEmpty ? shown : library.songs.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(shown.isEmpty && selected.isEmpty)
                }
            }
        }
    }

    private var filtered: [Song] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return library.songs }
        return library.songs.filter { song in
            let text = "\(song.title) \(song.artist) \(song.album)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}
