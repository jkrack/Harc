import HarcDomain

/// Presentation only; never interprets absent legacy provenance as confirmation.
public enum HarcSpeakerIdentityPresentation {
    public static func statusText(_ label: SpeakerLabel) -> String {
        guard label.personID != nil else { return "Label only" }
        switch label.isUserConfirmed {
        case true?: return "Confirmed"
        case false?: return "Auto-matched"
        case nil: return "Confirmation unknown"
        }
    }
}
