import SwiftUI

/// Fills in custom metadata fields across a whole set at once.
///
/// The per-track inspector is fine for a correction but hopeless for "every one
/// of these 24 songs is from a different film" — that is 24 sheets. This is a
/// spreadsheet over the job's tracks: one row per track, one column per custom
/// field, plus Fill Down for the columns where most rows share a value.
///
/// Title and artist are shown read-only, as row identity. Editing them here
/// would rename files (the rename template is `{artist} - {title}`), which is a
/// different and much more destructive operation than typing in a field — it
/// stays in the inspector where it is one deliberate act at a time.
struct BulkMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings

    let job: DownloadJob

    @State private var rows: [FieldRow] = []
    @State private var columns: [String] = []
    @State private var selection: Set<String> = []

    @State private var isAddingField = false
    @State private var newFieldName = ""
    @State private var renameTarget: ColumnRenameTarget?
    @State private var renameText = ""
    /// Columns removed in this session, so Save can strip their values from the
    /// files rather than just hiding them.
    @State private var removedColumns: [String] = []
    @State private var isSaving = false

    /// One editable row. `values` is keyed by column name; a column with no
    /// entry reads as empty.
    struct FieldRow: Identifiable, Equatable {
        let id: String
        let number: Int
        let title: String
        let artist: String
        let url: URL?
        let hasFile: Bool
        /// False for containers that cannot store custom frames — editing one
        /// would look like it worked and silently write nothing.
        let canStoreFields: Bool
        var values: [String: String]
        /// What the track carried when the sheet opened. Held per row so
        /// `pendingEdits` doesn't rescan `job.tracks` for every row on every
        /// view update, and so fields outside this set's columns survive.
        var original: [CustomField]

        /// Editable only when there is a file and its container can hold the
        /// fields. Both have to be true or the edit goes nowhere.
        var isEditable: Bool { hasFile && canStoreFields }

        var formatName: String {
            let ext = url?.pathExtension.uppercased() ?? ""
            return ext.isEmpty ? "These" : ".\(ext)"
        }
    }

    /// A ready-made column set for the case that prompted all this.
    private static let moviePreset = ["Movie", "Year", "Director", "Stars", "Studio"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if columns.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 460, idealHeight: 620)
        .onAppear(perform: load)
        .overlay { if store.bulkFieldSave != nil { savingOverlay } }
        // The write runs on the store, not here, so the sheet has to wait for it
        // rather than dismissing on the button press — otherwise the progress
        // overlay is never on screen to be seen.
        .onChange(of: store.bulkFieldSave == nil) { _, finished in
            if finished && isSaving { dismiss() }
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $isAddingField) { addFieldSheet }
        .sheet(item: $renameTarget) { target in renameSheet(for: target.name) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Metadata Table")
                    .font(.headline)
                Text("\(rows.count) tracks in \"\(job.playlistTitle)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Menu {
                Button("Add Field…") { newFieldName = ""; isAddingField = true }
                Divider()
                Section("Presets") {
                    Button("Movie Soundtrack") { applyPreset(Self.moviePreset) }
                }
            } label: {
                Label("Add Field", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            fillDownMenu
        }
        .padding()
    }

    /// Fill Down copies one row's value for a column into other rows.
    ///
    /// Source is the topmost selected row. With several rows selected it fills
    /// just those; with one selected it fills everything below it, which is the
    /// usual "this whole album is from the same film" case.
    private var fillDownMenu: some View {
        Menu {
            if fillSource == nil {
                Text("Select a row first")
            } else {
                ForEach(columns, id: \.self) { column in
                    Button("Fill \"\(column)\" (\(fillTargetCount) rows)") { fillDown(column: column) }
                }
                if columns.count > 1 {
                    Divider()
                    Button("Fill All Fields (\(fillTargetCount) rows)") {
                        for column in columns { fillDown(column: column) }
                    }
                }
            }
        } label: {
            Label("Fill Down", systemImage: "arrow.down.to.line")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(columns.isEmpty || rows.count < 2)
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("#") { row in
                Text("\(row.number)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(30)

            TableColumn("Title") { row in
                HStack(spacing: 4) {
                    if !row.hasFile {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("No file on disk — edits to this row can't be saved")
                    } else if !row.canStoreFields {
                        Image(systemName: "nosign")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("\(row.formatName) files can't store custom fields. Re-download this track as mp3, m4a or flac.")
                    }
                    Text(row.title).lineLimit(1).truncationMode(.tail)
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Artist") { row in
                Text(row.artist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 90, ideal: 140)

            TableColumnForEach(columns, id: \.self) { column in
                TableColumn(column) { row in
                    TextField(column, text: binding(rowID: row.id, column: column))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(!row.isEditable)
                }
                .width(min: 90, ideal: 130)
            }
        }
        .tableColumnHeaders(.visible)
        .contextMenu(forSelectionType: FieldRow.ID.self) { _ in
            ForEach(columns, id: \.self) { column in
                Button("Rename \"\(column)\"…") { renameText = column; renameTarget = ColumnRenameTarget(id: column) }
            }
            if !columns.isEmpty { Divider() }
            ForEach(columns, id: \.self) { column in
                Button("Delete \"\(column)\"", role: .destructive) { removeColumn(column) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tablecells")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No custom fields yet")
                .font(.headline)
            Text("Add a field to start describing these tracks — a movie title,\na year, a director, or anything else you want on the cards.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Field…") { newFieldName = ""; isAddingField = true }
                Button("Use Movie Soundtrack Preset") { applyPreset(Self.moviePreset) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if changedRowCount > 0 {
                Text("\(changedRowCount) track\(changedRowCount == 1 ? "" : "s") to update")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(changedRowCount == 0)
        }
        .padding()
    }

    private var savingOverlay: some View {
        let progress = store.bulkFieldSave
        return ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView(value: progress?.fraction ?? 0)
                    .frame(width: 240)
                Text("Writing tags — \(progress?.completed ?? 0) of \(progress?.total ?? 0)")
                    .font(.caption)
                if let title = progress?.currentTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 240)
                }
                Button("Stop") { store.bulkFieldSave?.isCancelled = true }
                    .controlSize(.small)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Sheets

    private var addFieldSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Field").font(.headline)
            TextField("Field name, e.g. Movie", text: $newFieldName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { if canAddField { addField() } }
            if !newFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !canAddField {
                Text("A field with that name already exists.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { isAddingField = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addField() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddField)
            }
        }
        .padding(20)
    }

    private func renameSheet(for target: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \"\(target)\"").font(.headline)
            TextField("Field name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { renameColumn(from: target, to: renameText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRename(to: renameText, from: target))
            }
        }
        .padding(20)
    }

    // MARK: - State

    private func load() {
        columns = job.customFieldNames
        // Columns a track carries that the set doesn't list yet — an imported
        // file, or fields written before the set had a column list.
        for track in job.tracks {
            for field in track.metadata?.customFields ?? [] {
                if !columns.contains(where: { $0.lowercased() == field.name.lowercased() }) {
                    columns.append(field.name)
                }
            }
        }

        rows = job.tracks.enumerated().map { index, track in
            var values: [String: String] = [:]
            for column in columns {
                values[column] = track.metadata?.customFields?.value(named: column) ?? ""
            }
            return FieldRow(
                id: track.id,
                number: index + 1,
                title: track.metadata?.title ?? track.title,
                artist: track.metadata?.artist ?? "",
                url: track.fileURL,
                hasFile: track.fileURL != nil,
                canStoreFields: track.fileURL.map(MetadataWriter.canStoreCustomFields) ?? false,
                values: values,
                original: track.metadata?.customFields ?? []
            )
        }
    }

    private func binding(rowID: String, column: String) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == rowID }?.values[column] ?? "" },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
                rows[index].values[column] = newValue
            }
        )
    }

    /// The tracks whose stored fields would actually change, mapped to the
    /// complete list to write.
    ///
    /// Computed from the resulting field list rather than from row equality: a
    /// deleted column makes every row differ, but only the rows that really
    /// held a value need rewriting, and each rewrite is an ffmpeg re-mux.
    private var pendingEdits: [String: [CustomField]] {
        var edits: [String: [CustomField]] = [:]
        for row in rows where row.isEditable {
            var fields = row.original
            for column in columns {
                fields.setValue(row.values[column] ?? "", named: column)
            }
            for removed in removedColumns {
                fields.setValue("", named: removed)
            }
            if fields != row.original { edits[row.id] = fields }
        }
        return edits
    }

    private var changedRowCount: Int { pendingEdits.count }

    // MARK: - Columns

    private var canAddField: Bool {
        let trimmed = newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !columns.contains { $0.lowercased() == trimmed.lowercased() }
    }

    private func addField() {
        guard canAddField else { return }
        insertColumn(newFieldName.trimmingCharacters(in: .whitespacesAndNewlines))
        newFieldName = ""
        isAddingField = false
    }

    private func applyPreset(_ names: [String]) {
        for name in names where !columns.contains(where: { $0.lowercased() == name.lowercased() }) {
            insertColumn(name)
        }
    }

    private func insertColumn(_ name: String) {
        columns.append(name)
        removedColumns.removeAll { $0.lowercased() == name.lowercased() }
        for index in rows.indices where rows[index].values[name] == nil {
            rows[index].values[name] = ""
        }
        store.addCustomFieldName(name, to: job)
    }

    private func canRename(to new: String, from old: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return false }
        return !columns.contains { $0.lowercased() == trimmed.lowercased() }
    }

    private func renameColumn(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRename(to: trimmed, from: old) else { return }

        if let index = columns.firstIndex(of: old) { columns[index] = trimmed }
        removedColumns.removeAll { $0.lowercased() == trimmed.lowercased() }
        for index in rows.indices {
            rows[index].values[trimmed] = rows[index].values.removeValue(forKey: old) ?? ""
        }
        // The old name must also be cleared from the files, so a rename reads
        // as a rename instead of leaving an orphan field behind.
        removedColumns.append(old)
        store.renameCustomFieldName(old, to: trimmed, in: job)
        renameTarget = nil
    }

    private func removeColumn(_ name: String) {
        columns.removeAll { $0 == name }
        for index in rows.indices { rows[index].values.removeValue(forKey: name) }
        removedColumns.append(name)
        store.removeCustomFieldName(name, from: job)
    }

    // MARK: - Fill down

    /// Topmost selected row, in table order.
    private var fillSource: FieldRow? {
        rows.first { selection.contains($0.id) }
    }

    private var fillTargets: [FieldRow] {
        guard let source = fillSource else { return [] }
        if selection.count > 1 {
            return rows.filter { selection.contains($0.id) && $0.id != source.id }
        }
        guard let start = rows.firstIndex(where: { $0.id == source.id }) else { return [] }
        return Array(rows.dropFirst(start + 1))
    }

    private var fillTargetCount: Int { fillTargets.count }

    private func fillDown(column: String) {
        guard let source = fillSource, let value = source.values[column] else { return }
        let targetIDs = Set(fillTargets.map(\.id))
        for index in rows.indices where targetIDs.contains(rows[index].id) {
            rows[index].values[column] = value
        }
    }

    // MARK: - Save

    private func save() {
        let edits = pendingEdits
        guard !edits.isEmpty else { dismiss(); return }
        isSaving = true
        store.saveCustomFields(edits, in: job, settings: settings)
        // The store declines the work if none of the edited tracks still has a
        // file — the job can change while this sheet is open. Without this the
        // sheet would sit waiting for a completion that never comes, with
        // Cancel disabled and no way out.
        if store.bulkFieldSave == nil {
            isSaving = false
            dismiss()
        }
    }
}

/// Wrapper so a column name can drive `.sheet(item:)` without making every
/// `String` in the module `Identifiable`.
struct ColumnRenameTarget: Identifiable {
    let id: String
    var name: String { id }
}
