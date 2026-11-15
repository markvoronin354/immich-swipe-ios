import Foundation
import Observation

/// A signed-in account as shown in the UI. Never holds the API key; that lives in the Keychain.
nonisolated struct Account: Codable, Hashable, Identifiable, Sendable {
    var userID: String
    var serverURL: URL
    var name: String?
    var email: String
    var avatarColor: String?
    var lastActive: Date

    var id: String { userID }
    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? email }
}

/// Owns the active session: which account is signed in and the client that talks to its server.
@Observable
final class SessionStore {
    enum SignInError: Error, Equatable, LocalizedError {
        case emptyFields
        case invalidServerURL
        /// Plain HTTP to a public host. The caller should confirm, then retry with `allowInsecure`.
        case insecureConnectionNeedsConfirmation

        var errorDescription: String? {
            switch self {
            case .emptyFields: "Enter your server address and API key."
            case .invalidServerURL: "That doesn't look like a server address. Include http:// or https://."
            case .insecureConnectionNeedsConfirmation: "This connection isn't encrypted."
            }
        }
    }

    private(set) var account: Account?
    private(set) var client: ImmichClient?
    private(set) var accounts: [Account] = []
    private(set) var connection: ConnectionEvent?

    /// One shuffle seed per launch, so shuffled decks stay put within a session (spec §3.4).
    let shuffleSeed = Int64(Date.now.timeIntervalSince1970 * 1000)

    private let defaults: UserDefaults
    private let session: URLSession
    private static let accountsKey = "accounts"
    private static let activeUserKey = "activeUserID"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        restore()
    }

    /// Server URLs from saved accounts, for suggestions on the sign-in screen.
    var knownServers: [String] {
        Array(Set(accounts.map(\.serverURL.absoluteString))).sorted()
    }

    /// Checks the API key against the server and makes that account active.
    func signIn(server serverText: String, apiKey rawKey: String, allowInsecure: Bool = false) async throws {
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverText.trimmingCharacters(in: .whitespaces).isEmpty, !apiKey.isEmpty else { throw SignInError.emptyFields }
        guard let serverURL = ImmichClient.normalizedServerURL(serverText) else { throw SignInError.invalidServerURL }
        if !allowInsecure, URLPolicy.isInsecureRemote(serverURL) { throw SignInError.insecureConnectionNeedsConfirmation }

        // No retries here, so a wrong address fails fast instead of after backoff.
        let probe = ImmichClient(serverURL: serverURL, apiKey: apiKey, session: session, retry: .none)
        AppLog.i("Auth", "Attempting connection to \(serverURL.absoluteString)")
        let user: User
        do {
            user = try await probe.getMyUser()
        } catch {
            AppLog.e("Auth", "Connection failed: \(error.localizedDescription)", error)
            throw error
        }
        AppLog.i("Auth", "Valid credentials. User: \(user.name ?? user.email) (\(user.id))")

        try Keychain.setAPIKey(apiKey, for: user.id)
        let signedIn = Account(userID: user.id, serverURL: serverURL, name: user.name, email: user.email, avatarColor: user.avatarColor, lastActive: .now)
        accounts.removeAll { $0.userID == user.id }
        accounts.insert(signedIn, at: 0)
        activate(signedIn, apiKey: apiKey)
        persist()
    }

    /// Switches to another saved account without asking for its key again.
    func switchTo(_ target: Account) throws {
        guard let apiKey = try Keychain.apiKey(for: target.userID) else {
            // The key is gone (for example after restoring to a new device), so the account can't be used.
            try forget(target)
            return
        }
        AppLog.i("Home", "Switching to account \(target.displayName) (\(target.userID))")
        var updated = target
        updated.lastActive = .now
        accounts = [updated] + accounts.filter { $0.userID != target.userID }
        activate(updated, apiKey: apiKey)
        persist()
    }

    /// Signs out of the active account but keeps it in the list for quick switching.
    func signOut() {
        AppLog.i("SessionManager", "Session cleared / user logged out")
        account = nil
        client = nil
        connection = nil
        defaults.removeObject(forKey: Self.activeUserKey)
    }

    /// Removes an account and its API key from this device.
    func forget(_ target: Account) throws {
        try Keychain.removeAPIKey(for: target.userID)
        accounts.removeAll { $0.userID == target.userID }
        if account?.userID == target.userID { signOut() }
        persist()
    }

    /// A request for an account's profile picture, signed with that account's own key, so saved
    /// accounts other than the active one show their pictures too. Nil if the key isn't on this device.
    func profileImageRequest(for account: Account) -> URLRequest? {
        guard let apiKey = try? Keychain.apiKey(for: account.userID) else { return nil }
        return ImmichClient(serverURL: account.serverURL, apiKey: apiKey, session: session)
            .authorizedRequest(for: .profileImage(userID: account.userID))
    }

    // MARK: Private

    private func activate(_ target: Account, apiKey: String) {
        AppLog.i("SessionManager", "Session initialized for user \(target.userID) at \(target.serverURL.absoluteString)")
        account = target
        connection = nil
        // Events arrive off the main actor. Weak so the client's callback doesn't keep the store alive.
        client = ImmichClient(serverURL: target.serverURL, apiKey: apiKey, session: session) { [weak self] event in
            let store = self
            Task { @MainActor in store?.connection = event }
        }
    }

    private func restore() {
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        guard let activeID = defaults.string(forKey: Self.activeUserKey),
              let active = accounts.first(where: { $0.userID == activeID }),
              let apiKey = try? Keychain.apiKey(for: activeID) else { return }
        activate(active, apiKey: apiKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
        if let account {
            defaults.set(account.userID, forKey: Self.activeUserKey)
        } else {
            defaults.removeObject(forKey: Self.activeUserKey)
        }
    }
}
