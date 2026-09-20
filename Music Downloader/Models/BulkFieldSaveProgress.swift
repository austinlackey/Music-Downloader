import Foundation

/// Progress of a bulk custom-field write.
///
/// A save is one ffmpeg re-mux per track, so a 60-track set takes tens of
/// seconds — long enough that the sheet has to show what is happening and offer
/// a way out.
nonisolated struct BulkFieldSaveProgress: Sendable, Equatable {
    var completed: Int
    var total: Int
    /// Title of the track currently being written.
    var currentTitle: String = ""
    /// Set by the sheet's Cancel button. Tracks already written stay written —
    /// each file is replaced atomically, so stopping leaves no half-tagged file.
    var isCancelled = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}
