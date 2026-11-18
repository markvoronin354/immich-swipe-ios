import SwiftUI

/// The profile button: the account's picture with a dot for the connection, opening the Account popup.
/// Put it in the toolbar of any screen that should offer the popup (and, through it, Settings).
struct ProfileButton: View {
    @Environment(SessionStore.self) private var session
    @Environment(Navigator.self) private var navigator
    @State private var isShowing = false
    /// Set by the sheet's Settings button. Settings opens once the sheet has finished closing.
    @State private var opensSettingsOnDismiss = false

    var body: some View {
        if let account = session.account {
            let level = ConnectionLevel(session.connection)
            Button {
                isShowing = true
            } label: {
                AccountAvatar(account: account, size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(level.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(account.displayName))
            .accessibilityValue(Text(level.title))
            .accessibilityHint("Opens your account")
            // Pushing Settings while the sheet is still sliding away made the two animations fight,
            // so the push waits until the sheet is gone.
            .sheet(isPresented: $isShowing, onDismiss: {
                guard opensSettingsOnDismiss else { return }
                opensSettingsOnDismiss = false
                navigator.openSettings()
            }) {
                ProfileSheet { opensSettingsOnDismiss = true }
            }
        }
    }
}

/// An account's picture, or its initial on the account's colour when there's no picture.
struct AccountAvatar: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.displayScale) private var displayScale

    let account: Account
    var size: CGFloat = 32

    @State private var picture: CGImage?

    var body: some View {
        let rgb = AvatarStyle.rgb(forColorName: account.avatarColor)
        let color = AvatarStyle.color(forColorName: account.avatarColor)
        ZStack {
            Circle().fill(color)
            if let picture {
                Image(decorative: picture, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else if let initial = AvatarStyle.initial(of: account.displayName) {
                Text(String(initial))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(AvatarStyle.prefersDarkText(onRGB: rgb) ? Color.black.opacity(0.87) : .white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(AvatarStyle.prefersDarkText(onRGB: rgb) ? Color.black.opacity(0.87) : .white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().stroke(color, lineWidth: max(1, size / 32)))
        .task(id: account.userID) {
            picture = nil
            // Immich answers 404 when there's no picture, which simply leaves the initial showing.
            guard let request = session.profileImageRequest(for: account) else { return }
            picture = try? await ThumbnailLoader.shared.image(for: request, maxPixelSize: Int(size * displayScale * 2))
        }
        .accessibilityHidden(true)
    }
}

/// The Account popup: who you are, whether the server is reachable, your saved accounts, and a way
/// into Settings.
struct ProfileSheet: View {
    /// Asks for Settings to open once this sheet has closed.
    var onOpenSettings: () -> Void = {}

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var user: User?
    @State private var accountToRemove: Account?
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                if let account = session.account {
                    Section {
                        ProfileHeader(account: account, user: user)
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        ConnectionCard(level: ConnectionLevel(session.connection))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    SavedAccountsSection(
                        currentID: account.userID,
                        onSwitch: switchTo,
                        onRemove: { accountToRemove = $0 },
                        onAdd: addAccount
                    )

                    // With several saved accounts, switching replaces signing out, as on Android.
                    if session.accounts.count <= 1 {
                        Section {
                            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                isConfirmingSignOut = true
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Section {
                        VStack(spacing: 6) {
                            Button("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                                openURL(URL(string: "https://github.com/markvoronin354/immich-swipe-ios")!)
                            }
                            .font(.subheadline.weight(.semibold))
                            Text(Self.versionText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            // Let the sheet's material show through instead of the list's own opaque grey.
            .scrollContentBackground(.hidden)
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape", action: openSettings)
                }
            }
            .task(id: session.account?.userID) {
                user = nil
                user = try? await session.client?.getMyUser()
            }
            .alert("Sign out?", isPresented: $isConfirmingSignOut) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    session.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out of this account? You can sign back in with the same key.")
            }
            // An alert, not a confirmation dialog: on iPhone that one hangs off the trash button with a pointer.
            .alert(
                "Remove account?",
                isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
                presenting: accountToRemove
            ) { account in
                Button("Remove \(account.displayName)", role: .destructive) { try? session.forget(account) }
                Button("Cancel", role: .cancel) {}
            } message: { account in
                Text("Are you sure you want to remove the account for \"\(account.displayName)\"? Its key is deleted from this device. Your server isn't changed.")
            }
        }
        .presentationDetents([.fraction(0.85), .large])
        // One background at every height. Left to the system, the sheet is glass when partly open and snaps
        // to opaque at full height, with no fade between the two.
        .presentationBackground(.regularMaterial)
    }

    private func openSettings() {
        onOpenSettings()
        dismiss()
    }

    private func switchTo(_ account: Account) {
        try? session.switchTo(account)
        dismiss()
    }

    private func addAccount() {
        // Signing out keeps this account saved and shows the sign-in screen for the new one.
        dismiss()
        session.signOut()
    }

    private static var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version)"
    }
}

private struct ProfileHeader: View {
    let account: Account
    let user: User?

    var body: some View {
        VStack(spacing: 6) {
            AccountAvatar(account: account, size: 96)
                .padding(.bottom, 10)
            Text(account.displayName)
                .font(.title2.bold())
            Text(account.email)
                .foregroundStyle(.secondary)

            if let used = user?.quotaUsageInBytes {
                StorageUsage(used: used, limit: user?.quotaSizeInBytes)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// "193.9 GB / Unlimited", with a bar when the account has a quota.
private struct StorageUsage: View {
    let used: Int64
    let limit: Int64?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Storage usage")
                    .foregroundStyle(.secondary)
                Spacer()
                if let limit, limit > 0 {
                    Text("\(used.formatted(.byteCount(style: .file))) / \(limit.formatted(.byteCount(style: .file)))")
                        .fontWeight(.bold)
                } else {
                    Text("\(used.formatted(.byteCount(style: .file))) / Unlimited")
                        .fontWeight(.bold)
                }
            }
            .font(.subheadline)

            if let limit, limit > 0 {
                ProgressView(value: min(Double(used) / Double(limit), 1))
            }
        }
    }
}

private struct ConnectionCard: View {
    let level: ConnectionLevel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(level.color)
                .frame(width: 8, height: 8)
            Text(level.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(level.color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A capsule, matching the rounder corners the list gives its rows: with a smaller corner radius the
        // row's own rounding cut into this card's border.
        .background(level.color.opacity(0.12), in: .capsule)
        .overlay(Capsule().strokeBorder(level.color.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct SavedAccountsSection: View {
    @Environment(SessionStore.self) private var session

    let currentID: String
    let onSwitch: (Account) -> Void
    let onRemove: (Account) -> Void
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach(session.accounts) { account in
                let isCurrent = account.userID == currentID
                HStack(spacing: 12) {
                    Button {
                        if !isCurrent { onSwitch(account) }
                    } label: {
                        HStack(spacing: 12) {
                            AccountAvatar(account: account, size: 36)
                                .overlay(alignment: .bottomTrailing) {
                                    if isCurrent {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white, Color.accentColor)
                                            .background(.background, in: .circle)
                                            .offset(x: 4, y: 4)
                                    }
                                }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                    .fontWeight(.medium)
                                Text(account.email)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])

                    if !isCurrent {
                        Button("Remove", systemImage: "trash") { onRemove(account) }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                    }
                }
            }

            Button("Add Another Account", systemImage: "person.badge.plus", action: onAdd)
        } header: {
            Label("Saved Accounts", systemImage: "person.2.fill")
        }
    }
}

#Preview("Account popup") {
    let accounts = [
        Account(userID: "p1", serverURL: URL(string: "https://photos.example.com")!, name: "Family_Media", email: "family@example.com", avatarColor: "yellow", lastActive: .now),
        Account(userID: "p2", serverURL: URL(string: "https://photos.example.com")!, name: "Mark Voronin", email: "mark@proton.me", avatarColor: "purple", lastActive: .now),
        Account(userID: "p3", serverURL: URL(string: "https://photos.example.com")!, name: "Innas_phone", email: "inna@example.com", avatarColor: "gray", lastActive: .now),
    ]
    let defaults = UserDefaults(suiteName: "preview-profile")!
    defaults.set(try! JSONEncoder().encode(accounts), forKey: "accounts")
    defaults.set("p1", forKey: "activeUserID")
    try? Keychain.setAPIKey("preview", for: "p1")
    return ProfileSheet()
        .environment(SessionStore(defaults: defaults))
        .environment(Navigator())
}
