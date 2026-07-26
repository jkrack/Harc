import Foundation

/// Count plus a noun, agreeing in number.
///
/// The Library's chips read "1 speakers" and "1 files" — visible in any
/// recording with a single speaker, which is most dictation-length captures
/// and any meeting Harc could only hear one side of.
///
/// SwiftUI's `^[\(n) speaker](inflect: true)` markup would do this, but only
/// through `LocalizedStringKey`; passed as a plain `String` — which is how
/// these call sites build their titles — the markup is rendered literally.
public enum Pluralize {
    /// `1 speaker`, `2 speakers`. English-only, matching the product.
    public static func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        let word = n == 1 ? singular : (plural ?? singular + "s")
        return "\(n) \(word)"
    }
}
