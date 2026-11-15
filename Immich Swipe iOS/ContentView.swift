import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var session
    @State private var navigator = Navigator()
    let decisions: DecisionStore

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.path) {
            if let account = session.account, let client = session.client {
                HomeView(account: account, model: HomeModel(client: client, userID: account.userID, decisions: decisions))
                    // A new identity per account, so switching accounts starts with a fresh model.
                    .id(account.userID)
            } else {
                LoginView()
            }
        }
        // Switching or signing out starts a new stack, so a pushed screen never outlives its account.
        .id(session.account?.userID)
        .environment(navigator)
        .onChange(of: session.account?.userID) { navigator.reset() }
    }
}

#Preview {
    ContentView(decisions: try! DecisionStore.inMemory())
        .environment(SessionStore(defaults: UserDefaults(suiteName: "preview-content")!))
}
