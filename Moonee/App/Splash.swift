import SwiftUI

extension View {
    /// The opening on a cold launch: the launch screen's picture (Moonee over the word "Moonee", `moonee.splash`) stays
    /// for a moment once the app is up, then fades into it (≈0.4 s in all). Apply once, outermost, so it also covers
    /// onboarding and the app lock (Face ID can run underneath; nothing behind it ever flashes).
    /// Launch with `-splash.off YES` to skip it (screenshots).
    func splash() -> some View { modifier(SplashModifier()) }
}

private struct SplashModifier: ViewModifier {
    // @State on the root view survives background → foreground, so the splash only shows on a cold launch.
    @State private var showing = !UserDefaults.standard.bool(forKey: "splash.off")

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(showing)
            .overlay {
                if showing {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            // The app is drawn underneath by now; a short beat so iOS's own launch fade doesn't double up.
                            try? await Task.sleep(for: .milliseconds(150))
                            withAnimation(.easeOut(duration: 0.25)) { showing = false }
                        }
                }
            }
    }
}

/// Exactly the launch screen (`UILaunchScreen`: LaunchBackground + `moonee.splash` at its own size, centred),
/// so there is no jump from iOS's picture to the app's.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.brandMint // = LaunchBackground
            Image("moonee.splash") // = UILaunchScreen.UIImageName
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Moonee"))
    }
}
