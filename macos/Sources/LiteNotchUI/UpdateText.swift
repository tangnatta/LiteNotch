import Foundation

/// The words and links of the update block in Settings › General.
enum UpdateText {
    /// What updates a Homebrew install: fixed text, the same as the core's
    /// (`update::BREW_COMMAND`, checked by `ParityTests`). What is copied is
    /// this, never text received from outside.
    static let brewCommand = "brew update && brew upgrade --cask litenotch"

    /// Release pages live here; nothing else is opened from an update notice.
    static let releasesPage = "https://github.com/tangnatta/LiteNotch/releases"

    static func caption(_ u: UpdateView) -> String {
        switch u.status {
        case .idle, .unknown: return "Not checked yet."
        case .checking: return "Asking GitHub\u{2026}"
        case .upToDate: return "You have the latest version."
        case .available: return "A newer version is available."
        case .failed: return "Couldn\u{2019}t reach GitHub. Try again later."
        }
    }

    /// The page to open, only if it is one of ours.
    static func releasePage(_ s: String?) -> URL? {
        guard let s, s.hasPrefix(releasesPage), s.count <= 300,
            s.dropFirst(releasesPage.count).allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }),
            let url = URL(string: s), url.scheme == "https", url.host == "github.com"
        else { return nil }
        return url
    }
}
