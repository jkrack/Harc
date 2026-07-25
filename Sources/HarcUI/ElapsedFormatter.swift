import Foundation

/// Recording elapsed time, formatted the one way Harc formats it.
///
/// The menu-bar panel grew its own copy of this arithmetic; the Library's live
/// transcript needs the same string, and two hand-rolled versions of "seconds
/// to m:ss" is how a UI ends up showing 61:00 in one place and 1:01:00 in
/// another.
public enum ElapsedFormatter {
    /// `m:ss`, promoted to `h:mm:ss` once an hour has passed — meeting capture
    /// routinely runs past the hour, and `73:24` is not a duration anyone
    /// reads correctly at a glance.
    public static func string(since start: Date, now: Date = Date()) -> String {
        string(seconds: Int(now.timeIntervalSince(start)))
    }

    public static func string(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
