import OSLog
import SwiftUI

/// The top of the view tree: switches on `SessionStore.phase`, hosts root-level toasts, asks for a new
/// password after a password-reset link (`NewPasswordView`, over any phase), and forwards URLs and
/// scene-phase changes to `AppModel`.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch session.phase {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .signedOut:
                if AccountMode.current == .emailPassword {
                    AuthFlowView()
                        .transition(.opacity)
                } else {
                    // Anonymous accounts: Get started creates one.
                    WelcomeView()
                        .transition(.opacity)
                }
            case .needsUsername:
                UsernameView()
                    .transition(.opacity)
            case .needsStarter:
                StarterFlowView(mode: .onboarding)
                    .transition(.opacity)
            case .ready:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.phase)
        .toastHost(clearance: session.phase == .ready ? .tabBar : .bottomButton)
        .sheet(isPresented: isRecoveringPassword) {
            NewPasswordView()
                .toastHost()
        }
        .onAppear { app.start() }
        .onOpenURL { url in
            Task { await app.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await app.sceneDidBecomeActive() }
            case .background:
                Task { await app.sceneDidEnterBackground() }
            default:
                break
            }
        }
    }

    /// Shows `NewPasswordView` while a password-reset session waits for a new password. Dismissing it
    /// (swipe or "Not now") keeps the user signed in with the old password.
    private var isRecoveringPassword: Binding<Bool> {
        Binding(
            get: { session.isRecoveringPassword },
            set: { if !$0 { session.cancelPasswordRecovery() } }
        )
    }
}

/// Launch: `Ground` with the wordmark. A spinner appears only after a second; a failed launch
/// (offline on the first sign-in, or when the anonymous account can't be created) shows the message
/// and Try again.
struct LaunchView: View {
    @Environment(SessionStore.self) private var session
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Wordmark(textStyle: .largeTitle)
            if let message = session.launchError {
                VStack(spacing: Theme.Spacing.m) {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        isRetrying = true
                        Task {
                            await session.retryLaunch()
                            isRetrying = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(isRetrying)
                }
                .padding(.horizontal, Theme.Spacing.xl)
            } else {
                DelayedProgressView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ground.ignoresSafeArea())
    }
}

/// Shown instead of the app when the build is misconfigured (missing Supabase keys in Info.plist).
/// A developer error; users never see it in a correctly built app.
struct ConfigurationErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Wordmark(textStyle: .largeTitle)
            Text("Quoted can\u{2019}t start")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ground.ignoresSafeArea())
    }
}

#Preview("Launch") {
    LaunchView()
        .previewEnvironment(.preview(phase: .launching))
}

#Preview("Root, ready") {
    RootView()
        .appEnvironment(.preview())
}

#Preview("Configuration error") {
    ConfigurationErrorView(message: "Info.plist key SupabaseURL is missing or empty. Set it from Config/*.xcconfig.")
}
