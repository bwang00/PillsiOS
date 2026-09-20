import Foundation

/// Static app-level metadata surfaced in Settings and disclosures.
enum AppInfo {
    /// Public privacy policy (bilingual, hosted on our server).
    static let privacyURL = URL(string: "https://pills.blueping.xyz/privacy")!

    /// Public support page (bilingual, hosted on our server).
    static let supportURL = URL(string: "https://pills.blueping.xyz/support")!

    /// Human-readable version, e.g. "1.0.0 (5)".
    static var versionDisplay: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
