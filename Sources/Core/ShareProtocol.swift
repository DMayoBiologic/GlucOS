import Foundation

// Sharing live readings: what the iPhone app says to the relay (the owner's share links) and to
// the public `share` function (followers). The TypeScript in supabase/functions/relay/sharing.ts,
// engine.ts and supabase/functions/share/index.ts mirrors these. See docs/Sharing.md.
//
//   Relay, with the relay secret:
//     GET  /v1/shares                        → [ShareInfo]
//     POST /v1/shares        CreateShare     → CreatedShare
//     POST /v1/shares/revoke {id}            → [ShareInfo]
//   Share function, with `Authorization: Bearer <share token>`:
//     GET  /v1/snapshot                      → ShareSnapshot
//     POST /v1/follow        FollowRegistration → FollowStatus
//     POST /v1/unfollow      {installation}  → {ok}

/// One of the owner's live share links.
struct ShareInfo: Codable, Hashable, Identifiable {
    var id: String
    /// Whose readings these are, shown to followers.
    var label: String
    /// Seconds since 1970.
    var createdAt: Double
    /// nil: until the owner stops sharing.
    var expiresAt: Double?
    var lastViewedAt: Double?
    /// Follower phones with GlucOS.
    var followers: Int

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { now.timeIntervalSince1970 >= $0 } ?? false
    }
}

struct CreateShare: Codable, Hashable {
    var label: String
    /// Seconds from now; nil: until revoked.
    var expiresIn: Double?
}

struct CreatedShare: Codable, Hashable {
    var share: ShareInfo
    /// Only given out once: the relay keeps a hash of it, not the token.
    var token: String
    var url: String
}

struct RevokeShare: Codable, Hashable {
    var id: String
}

/// What someone with the link sees.
struct ShareSnapshot: Codable, Hashable {
    var label: String
    var expiresAt: Double?
    /// The owner's latest Lock Screen card, in the owner's units and target range.
    var card: GlucoseActivityState?
    var updatedAt: Double?
    /// The share's id: a follower's Live Activity carries it, so the relay and the app know whose it is.
    var followID: String
}

/// What a follower phone tells the share function. nil means unchanged.
struct FollowRegistration: Codable, Hashable {
    /// A random id for this phone, kept for as long as the app is installed.
    var installation: String
    var apnsEnvironment: String?
    var pushToStartToken: String?
    var activityID: String?
    var activityToken: String?
    var endedActivityID: String?
    var liveActivityEnabled: Bool?

    init(installation: String) { self.installation = installation }
}

struct FollowStatus: Codable, Hashable {
    var followID: String
    var label: String
    var expiresAt: Double?
    var liveActivityEnabled: Bool
}

/// How long a new share link lasts.
enum ShareDuration: String, CaseIterable, Identifiable, Codable {
    case hour, eightHours, day, week, untilStopped

    var id: String { rawValue }

    var seconds: Double? {
        switch self {
        case .hour: return 3600
        case .eightHours: return 8 * 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .untilStopped: return nil
        }
    }

    var label: String {
        switch self {
        case .hour: return "1 hour"
        case .eightHours: return "8 hours"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .untilStopped: return "Until I stop sharing"
        }
    }
}

/// Follow links: https://gluc-os-seven.vercel.app/share/#<token>, or glucos://follow#<token>
/// from the web view's "Open in GlucOS" button. The token is in the fragment so it never reaches
/// a web server.
enum FollowLink {
    static let viewerURL = "https://gluc-os-seven.vercel.app/share/"

    /// The public `share` function, in the same Supabase project as the relay and logbook sync.
    static let serviceURL = URL(string: "https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/share")!

    static func url(token: String) -> URL? { URL(string: "\(viewerURL)#\(token)") }

    static func appURL(token: String) -> URL? { URL(string: "glucos://follow#\(token)") }

    /// The share token in a link (or pasted text with a link in it), if it has one.
    static func token(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToken(trimmed) { return trimmed }
        for word in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            if let url = URL(string: String(word)), let t = token(from: url) { return t }
        }
        return nil
    }

    static func token(from url: URL) -> String? {
        let isApp = url.scheme == "glucos" && url.host == "follow"
        let isWeb = url.scheme == "https" && url.absoluteString.hasPrefix(viewerURL)
        guard isApp || isWeb else { return nil }
        if let f = url.fragment, isToken(f) { return f }
        let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value
        return t.flatMap { isToken($0) ? $0 : nil }
    }

    /// 32 random bytes, base64url without padding: 43 characters.
    static func isToken(_ s: String) -> Bool {
        s.count == 43 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The words that go with a share link, in the share sheet and in Messages.
enum ShareMessage {
    /// The label a link gets when the owner leaves their name blank.
    static let defaultLabel = "GlucOS"

    static func text(label: String) -> String {
        "Follow \(label == defaultLabel ? "my" : "\(label)'s") glucose live in GlucOS:"
    }

    /// "My glucose" or "Declan's glucose".
    static func title(label: String) -> String {
        "\(label == defaultLabel ? "My" : "\(label)'s") glucose"
    }

    static func cleanLabel(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultLabel : String(t.prefix(40))
    }
}
