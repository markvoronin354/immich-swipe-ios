import SwiftUI

/// Sign-in with a server address and an Immich API key, plus quick switching to saved accounts.
struct LoginView: View {
    @Environment(SessionStore.self) private var session

    @State private var server = ""
    @State private var apiKey = ""
    @State private var isKeyVisible = false
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var isConfirmingInsecure = false
    @State private var isShowingKeyTutorial = false
    @State private var isShowingLogs = false

    private var canSignIn: Bool { !isSigningIn && !server.isEmpty && !apiKey.isEmpty }
    /// With saved accounts, this screen was reached by adding an account, so offer a way back.
    private var previousAccount: Account? { session.accounts.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Image("ImmichSwipeLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .accessibilityHidden(true)
                    Image("ImmichSwipeText")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 48)
                        .accessibilityLabel(Text(verbatim: "Immich Swipe"))
                }
                .padding(.top, previousAccount == nil ? 40 : 0)
                .padding(.bottom, 32)

                VStack(spacing: 12) {
                    FieldContainer {
                        TextField("Server URL", text: $server, prompt: Text("Server URL"))
                            .serverAddressInput()
                    }
                    FieldContainer {
                        HStack {
                            Group {
                                if isKeyVisible {
                                    TextField("API Key", text: $apiKey, prompt: Text("API Key"))
                                } else {
                                    SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                                }
                            }
                            .serverAddressInput()
                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")
                        }
                    }
                }

                Button("How to create an API Key?") { isShowingKeyTutorial = true }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    .padding(.leading, 4)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }

                Button {
                    signIn(allowInsecure: false)
                } label: {
                    Group {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Label("Login", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!canSignIn)
                .padding(.top, 28)

                Button("Clear", systemImage: "xmark") {
                    server = ""
                    apiKey = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 20)

                // Version and a way to the logs, so they can be sent even when signing in fails, as on Android.
                HStack(spacing: 4) {
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text(verbatim: "v\(version)")
                            .foregroundStyle(.tertiary)
                    }
                    Button("Logs") { isShowingLogs = true }
                        .fontWeight(.semibold)
                }
                .font(.footnote)
                .padding(.top, 32)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.groupedBackground.ignoresSafeArea())
        .navigationTitle(previousAccount == nil ? "" : String(localized: "Add Account"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(previousAccount == nil ? .hidden : .automatic, for: .navigationBar)
        #endif
        .toolbar {
            if let previousAccount {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", systemImage: "chevron.backward") { goBack(to: previousAccount) }
                }
            }
        }
        .onAppear {
            if server.isEmpty, let recent = session.accounts.first {
                server = recent.serverURL.absoluteString
            }
        }
        .sheet(isPresented: $isShowingLogs) {
            NavigationStack {
                LogsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { isShowingLogs = false }
                        }
                    }
            }
        }
        .alert("Creating an API Key", isPresented: $isShowingKeyTutorial) {
            Button("Got it!", role: .cancel) {}
        } message: {
            Text("""
            1. Open your Immich Web Interface (creating keys is not supported in the mobile app).
            2. Go to Account Settings > API Keys.
            3. Click "New API Key" and name it "Immich Swipe".
            4. Under Permissions, select:
            • Asset (All)
            • album.read
            • album.update
            • albumAsset.create
            • duplicate.read
            • user.read
            • userProfileImage.read
            5. Click Create, then copy and paste the key here.
            """)
        }
        .alert("Connect without encryption?", isPresented: $isConfirmingInsecure) {
            Button("Connect Anyway", role: .destructive) { signIn(allowInsecure: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This server uses plain HTTP over the internet, so your API key will be sent unencrypted. Only continue if you trust every network between you and the server.")
        }
    }

    private func signIn(allowInsecure: Bool) {
        errorMessage = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                try await session.signIn(server: server, apiKey: apiKey, allowInsecure: allowInsecure)
                apiKey = ""
            } catch SessionStore.SignInError.insecureConnectionNeedsConfirmation {
                isConfirmingInsecure = true
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func goBack(to account: Account) {
        do {
            try session.switchTo(account)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Plain-language versions of the failures people actually hit when signing in.
    private static func message(for error: Error) -> String {
        switch error {
        case ImmichError.http(status: 401, _), ImmichError.http(status: 403, _):
            return String(localized: "The server rejected this API key. Check that it was copied in full and hasn't been deleted.")
        case ImmichError.http(status: 404, _):
            return String(localized: "No Immich server was found at that address. Check the address and port.")
        case let urlError as URLError where urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed:
            return String(localized: "Couldn't find that server. Check the address, or that you're on the right network.")
        case let urlError as URLError where urlError.code == .cannotConnectToHost || urlError.code == .timedOut:
            return String(localized: "Couldn't reach the server. Check that it's running and the port is right.")
        case is DecodingError:
            return String(localized: "That address answered, but it doesn't look like an Immich server.")
        default:
            return error.localizedDescription
        }
    }
}

/// Filled rounded row in the system's grouped-form style; adapts to light and dark mode.
private struct FieldContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension Color {
    static var groupedBackground: Color {
        #if os(iOS) || os(visionOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var fieldBackground: Color {
        #if os(iOS) || os(visionOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

private extension View {
    /// URL keyboard, no autocorrection or auto-capitalisation where the platform has them.
    func serverAddressInput() -> some View {
        #if os(iOS) || os(visionOS)
        self
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

#Preview {
    NavigationStack {
        LoginView()
    }
    .environment(SessionStore(defaults: UserDefaults(suiteName: "preview-login")!))
}
