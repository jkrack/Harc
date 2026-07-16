import Foundation

/// Deletes orphaned dictation WAVs left in `~/Library/Caches/Harc/dictation/`
/// when the app dies mid-dictation.
///
/// Unlike meeting recordings, dictation clips are disposable: they must NEVER
/// be routed into the recording recovery inbox (`RecordingCacheRecovery` /
/// `RecoveryQueue`). A crash mid-dictation loses at most one spoken sentence —
/// just delete the leftovers.
public enum DictationCacheCleaner {
    /// Matches `MicDictationRecorder.newCacheURL()`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Harc/dictation", isDirectory: true)
    }

    /// Delete `.wav` files in `directory` (non-recursive) whose modification
    /// date is older than `maxAge`. The age guard protects a dictation that is
    /// live right now — its WAV is being written continuously, so its
    /// modification date stays fresh. Missing directory is a no-op.
    ///
    /// - Returns: number of files deleted.
    @discardableResult
    public static func cleanOrphans(
        directory: URL = defaultDirectory,
        olderThan maxAge: TimeInterval = 60 * 60
    ) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var deleted = 0
        for url in files where url.pathExtension.lowercased() == "wav" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified < cutoff else {
                continue
            }
            if (try? fm.removeItem(at: url)) != nil {
                deleted += 1
            }
        }
        return deleted
    }
}
