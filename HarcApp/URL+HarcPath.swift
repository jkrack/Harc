import Foundation

extension URL {
    /// If this URL matches the Harc layout `.../YYYY-MM-DD/HH-mm-ss.wav`, parse
    /// the date + time into a Date in the current locale.
    func startedAtFromHarcPath() -> Date? {
        let day = self.deletingLastPathComponent().lastPathComponent
        let time = self.deletingPathExtension().lastPathComponent
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: "\(day) \(time)")
    }
}
