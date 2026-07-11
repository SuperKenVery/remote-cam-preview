import SwiftUI

@main
struct RemoteCamPreviewApp: App {
    @State private var dependencies: AppDependencies
    @State private var session: AppSession

    init() {
        let dependencies = AppDependencies()
        _dependencies = State(initialValue: dependencies)
        _session = State(initialValue: AppSession(dependencies: dependencies))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(session: session)
                .environment(dependencies)
        }
    }
}

private struct AppRootView: View {
    @Bindable var session: AppSession

    var body: some View {
        NavigationStack(path: $session.routePath) {
            RoleSelectionView(session: session)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .session:
                        SessionView(session: session)
                    }
                }
        }
        .task { await session.prepare() }
    }
}

