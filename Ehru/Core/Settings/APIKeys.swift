import Foundation
import Security

/// The personal API keys a listener can add for extra metadata and artwork sources.
enum APIKeyKind: String, CaseIterable, Identifiable, Sendable {
    case lastFm
    case fanartTv
    case discogs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastFm: "Last.fm API key"
        case .fanartTv: "Fanart.tv API key"
        case .discogs: "Discogs personal access token"
        }
    }

    var help: String {
        switch self {
        case .lastFm: "Adds Last.fm to Fix Tags. Create one at last.fm/api/account/create."
        case .fanartTv: "Adds Fanart.tv artist photos and album covers. Get one at fanart.tv/get-an-api-key."
        case .discogs: "Adds Discogs artist photos and album covers. Generate one at discogs.com/settings/developers."
        }
    }
}

/// API keys kept in the iOS Keychain, on this device only: never in the app's files, its settings
/// or its build, so a shared IPA or repository carries none.
final class APIKeys: @unchecked Sendable {
    static let shared = APIKeys()

    private let service = "com.lochanpthakke.empee3.apikeys"
    private let lock = NSLock()
    private var cache: [APIKeyKind: String?] = [:]

    func value(_ kind: APIKeyKind) -> String? {
        lock.withLock {
            if let cached = cache[kind] { return cached }
            let loaded = read(kind)
            cache[kind] = loaded
            return loaded
        }
    }

    func isSet(_ kind: APIKeyKind) -> Bool { value(kind) != nil }

    /// Saves (or, for a blank value, removes) a key.
    func set(_ kind: APIKeyKind, _ value: String?) {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            let query = baseQuery(kind)
            SecItemDelete(query as CFDictionary)
            if let clean, !clean.isEmpty {
                var add = query
                add[kSecValueData as String] = Data(clean.utf8)
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
                cache[kind] = clean
            } else {
                cache[kind] = .some(nil)
            }
        }
    }

    private func baseQuery(_ kind: APIKeyKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: kind.rawValue]
    }

    private func read(_ kind: APIKeyKind) -> String? {
        var query = baseQuery(kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
