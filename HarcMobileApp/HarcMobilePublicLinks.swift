import Foundation

enum HarcMobilePublicLinks {
    static var privacyPolicy: URL? {
        httpsURL(forInfoDictionaryKey: "HarcPrivacyPolicyURL")
    }

    private static func httpsURL(
        forInfoDictionaryKey key: String
    ) -> URL? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key)
                as? String,
            let url = URL(string: value),
            url.scheme == "https",
            url.host != nil
        else {
            return nil
        }
        return url
    }
}
