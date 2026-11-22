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
        /// A custom header has an empty or invalid name or value, or its name repeats.
        case invalidHeaders
        /// Plain HTTP to a public host. The caller should confirm, then retry with `allowInsecure`.
        case insecureConnectionNeedsConfirmation
        /// The server works but something will go wrong later: it is too old to save rotations, or the key
        /// lacks permissions the app uses. The caller should say so, then retry with `acknowledgeWarnings`
        /// if the user carries on.
        case warnings(outdatedServer: ServerVersion?, missingPermissions: [String])
        /// The server refused the key, and says which permissions it lacks.
        case accessDenied(missing: [String])

        /// Warnings the user can read and carry on past, unlike a failure.
        var isServerWarning: Bool {
            if case .warnings = self { true } else { false }
        }

        var errorDescription: String? {
            switch self {
            case .emptyFields: "Enter your server address and API key."
            case .invalidServerURL: "That doesn't look like a server address. Include http:// or https://."
            case .invalidHeaders: String(localized: "A custom header isn't valid. Names can't be empty or contain spaces, values need visible characters, and x-api-key is set by the app.")
            case .insecureConnectionNeedsConfirmation: "This connection isn't encrypted."
            case .warnings(let outdated, let missing):
                [
                    outdated.map { String(localized: "This server runs Immich \($0.description). Saving a photo's rotation to the server needs \(ServerVersion.rotationEdits.description) or newer, so rotations you make here won't be saved there.") },
                    missing.isEmpty ? nil : String(localized: "Your API key is missing these permissions: \(missing.formatted()). Features that need them won't work until you add them to the key in Immich."),
                ].compactMap { $0 }.joined(separator: "\n\n")
            case .accessDenied(let missing): String(localized: "Access denied. Your API key is missing these permissions: \(missing.formatted()).")
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
    static let accountsKey = "accounts"
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
    func signIn(server serverText: String, apiKey rawKey: String, allowInsecure: Bool = false, acknowledgeWarnings: Bool = false, headers: [String: String] = [:]) async throws {
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverText.trimmingCharacters(in: .whitespaces).isEmpty, !apiKey.isEmpty else { throw SignInError.emptyFields }
        guard let serverURL = ImmichClient.normalizedServerURL(serverText) else { throw SignInError.invalidServerURL }
        if !allowInsecure, URLPolicy.isInsecureRemote(serverURL) { throw SignInError.insecureConnectionNeedsConfirmation }

        // No retries here, so a wrong address fails fast instead of after backoff.
        let probe = ImmichClient(serverURL: serverURL, apiKey: apiKey, headers: headers, session: session, retry: .none)
        AppLog.i("Auth", "Attempting connection to \(serverURL.absoluteString)")
        let user: User
        do {
            user = try await probe.getMyUser()
        } catch {
            AppLog.e("Auth", "Connection failed: \(error.localizedDescription)", error)
            // A refusal means the key lacks a permission: say which, when the server will tell.
            if case ImmichError.http(status: 403, _) = error {
                let missing = await probe.missingPermissions()
                if !missing.isEmpty { throw SignInError.accessDenied(missing: missing) }
            }
            throw error
        }
        AppLog.i("Auth", "Valid credentials. User: \(user.name ?? user.email) (\(user.id))")

        // Best effort: a server that doesn't say which version it runs, or what the key can do, warns of nothing.
        let version = try? await probe.getServerVersion()
        AppLog.i("Auth", "Server version: \(version?.description ?? "unknown")")
        let outdated = version.flatMap { $0 < ServerVersion.rotationEdits ? $0 : nil }
        if let outdated {
            AppLog.w("Auth", "Server \(outdated) is older than \(ServerVersion.rotationEdits): photo rotations can't be saved to it")
        }
        let missing = await probe.missingPermissions()
        if !missing.isEmpty {
            AppLog.w("Auth", "API key lacks: \(missing.joined(separator: ", "))")
        }
        if (outdated != nil || !missing.isEmpty), !acknowledgeWarnings {
            throw SignInError.warnings(outdatedServer: outdated, missingPermissions: missing)
        }

        try Keychain.setAPIKey(apiKey, for: user.id)
        try Keychain.setHeaders(headers, for: user.id)
        let signedIn = Account(userID: user.id, serverURL: serverURL, name: user.name, email: user.email, avatarColor: user.avatarColor, lastActive: .now)
        accounts.removeAll { $0.userID == user.id }
        accounts.insert(signedIn, at: 0)
        activate(signedIn, apiKey: apiKey, headers: headers)
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
        activate(updated, apiKey: apiKey, headers: Keychain.headers(for: target.userID))
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
        try Keychain.removeHeaders(for: target.userID)
        accounts.removeAll { $0.userID == target.userID }
        if account?.userID == target.userID { signOut() }
        persist()
    }

    /// A request for an account's profile picture, signed with that account's own key, so saved
    /// accounts other than the active one show their pictures too. Nil if the key isn't on this device.
    func profileImageRequest(for account: Account) -> URLRequest? {
        guard let apiKey = try? Keychain.apiKey(for: account.userID) else { return nil }
        return ImmichClient(serverURL: account.serverURL, apiKey: apiKey, headers: Keychain.headers(for: account.userID), session: session)
            .authorizedRequest(for: .profileImage(userID: account.userID))
    }

    // MARK: Private

    private func activate(_ target: Account, apiKey: String, headers: [String: String]) {
        AppLog.i("SessionManager", "Session initialized for user \(target.userID) at \(target.serverURL.absoluteString)")
        account = target
        connection = nil
        // Events arrive off the main actor. Weak so the client's callback doesn't keep the store alive.
        client = ImmichClient(serverURL: target.serverURL, apiKey: apiKey, headers: headers, session: session) { [weak self] event in
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
        activate(active, apiKey: apiKey, headers: Keychain.headers(for: activeID))
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
